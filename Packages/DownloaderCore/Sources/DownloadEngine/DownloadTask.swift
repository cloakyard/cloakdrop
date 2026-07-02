import Foundation
import DownloadModels
import DownloadPersistence

/// Why a running transfer stopped, so `run()` can record the right terminal state.
enum StopReason: Sendable {
    case pause
    case cancel
}

/// Drives a single download end to end.
///
/// One actor instance owns one `Download`. It probes the server, plans segments, transfers
/// them in parallel (each segment resilient to drops via retry+resume), throttles to any
/// speed limit, streams progress, then finalizes and verifies the file. All mutable state
/// is actor-isolated; the concurrent segment workers report back through actor methods.
actor DownloadTask {
    private var download: Download
    private let httpClient: any HTTPClient
    private let store: any DownloadStore
    private let globalLimiter: BandwidthLimiter
    private let settings: EngineSettings
    private let remuxer: any Remuxer
    private let signatureInspector: any CodeSignatureInspecting
    private let emit: @Sendable (EngineEvent) -> Void

    private var stopReason: StopReason?
    private let clock = ContinuousClock()
    private var speedSampler = SpeedSampler()
    private var lastEmit: ContinuousClock.Instant
    private var lastPersist: ContinuousClock.Instant

    init(
        download: Download,
        httpClient: any HTTPClient,
        store: any DownloadStore,
        globalLimiter: BandwidthLimiter,
        settings: EngineSettings,
        remuxer: any Remuxer = PassthroughRemuxer(),
        signatureInspector: any CodeSignatureInspecting = SecCodeSignatureInspector(),
        emit: @escaping @Sendable (EngineEvent) -> Void
    ) {
        self.download = download
        self.httpClient = httpClient
        self.store = store
        self.globalLimiter = globalLimiter
        self.settings = settings
        self.remuxer = remuxer
        self.signatureInspector = signatureInspector
        self.emit = emit
        let now = ContinuousClock().now
        self.lastEmit = now
        self.lastPersist = now
    }

    var snapshot: Download { download }

    /// Request a stop. The manager cancels this task's enclosing `Task` immediately after.
    func requestStop(_ reason: StopReason) {
        stopReason = reason
    }

    /// Run the transfer to a terminal or paused state, returning the final record.
    func run() async -> Download {
        stopReason = nil
        await transition(to: .downloading)
        if download.startedAt == nil { download.startedAt = Date() }

        // Authorize writes into a user-chosen, sandboxed destination for the whole transfer.
        let scope = SecurityScope(bookmark: download.destinationBookmark)
        let accessGranted = scope.start()
        defer { scope.stop() }

        do {
            // A user- or rule-chosen destination whose security-scoped bookmark no longer resolves
            // (folder moved/deleted, or access revoked) can't be written to. Fail fast with a clear
            // reason instead of a cryptic write error mid-transfer. The default Downloads folder
            // carries no bookmark and is covered by the entitlement, so it's unaffected.
            if scope.hasBookmark && !accessGranted {
                throw DownloadError.fileSystem(reason: "the destination folder is no longer accessible — choose it again")
            }
            if download.mediaPlan != nil {
                try await transferMedia()
            } else {
                try await prepareIfNeeded()
                try await transferSegments()
            }
            try await finalize()
            download.status = .completed
            download.completedAt = Date()
            await persist()
            emit(.downloadUpdated(download))
            return download
        } catch is CancellationError {
            return await handleStop()
        } catch {
            if Task.isCancelled { return await handleStop() }
            download.status = .failed(reason: Self.message(for: error))
            await persist()
            emit(.downloadUpdated(download))
            return download
        }
    }

    // MARK: Preparation

    /// Probe the server, plan segments, and create the part file (skipped on resume).
    private func prepareIfNeeded() async throws {
        // Resuming a partial, resumable download: make sure the server's copy hasn't changed under us.
        // If the ETag (or size) differs from probe time, the bytes on disk are stale — discard them
        // and start over, rather than stitching old and new content into a corrupt file.
        if !download.segments.isEmpty, download.supportsResume, await remoteContentChanged() {
            SegmentedFileWriter.discardPartData(for: download)
            download.segments = []
            download.startedAt = Date()
            await persist()
            emit(.downloadUpdated(download))
        }

        if download.segments.isEmpty {
            let head = try await httpClient.probe(
                HTTPDownloadRequest(
                    url: download.url,
                    headers: download.requestHeaders,
                    username: download.username,
                    password: download.password
                )
            )
            download.totalBytes = head.totalBytes
            download.supportsResume = head.acceptsRanges && head.totalBytes != nil
            download.etag = head.etag

            if let total = head.totalBytes, head.acceptsRanges, total >= settings.minimumSegmentSizeBytes * 2 {
                let requested = min(settings.maxSegmentCount, max(1, segmentCountForThisDownload()))
                download.segments = SegmentPlanner.plan(
                    totalBytes: total,
                    requestedSegments: requested,
                    minimumSegmentSize: settings.minimumSegmentSizeBytes
                )
            } else if let total = head.totalBytes, total > 0 {
                download.segments = [DownloadSegment(id: 0, start: 0, end: total - 1)]
            } else {
                // Unknown size: single open-ended stream.
                download.segments = [DownloadSegment(id: 0, start: 0, end: Int64.max - 1)]
            }
            await persist()
            emit(.downloadUpdated(download))
        }
        try SegmentedFileWriter.prepare(partPath: download.partFilePath, totalBytes: download.totalBytes)
    }

    private func segmentCountForThisDownload() -> Int {
        settings.defaultSegmentCount
    }

    /// Best-effort check that the remote resource is still the one we began downloading. Returns
    /// `true` only on positive evidence of change (a differing ETag, or a differing size) — a failed
    /// or inconclusive probe returns `false`, so a transient hiccup never triggers a needless restart.
    private func remoteContentChanged() async -> Bool {
        guard let head = try? await httpClient.probe(
            HTTPDownloadRequest(
                url: download.url,
                headers: download.requestHeaders,
                username: download.username,
                password: download.password
            )
        ) else { return false }
        if let old = download.etag, let new = head.etag, !old.isEmpty, !new.isEmpty {
            return old != new
        }
        if let oldSize = download.totalBytes, let newSize = head.totalBytes {
            return oldSize != newSize
        }
        return false
    }

    // MARK: Transfer

    private func transferSegments() async throws {
        let incomplete = download.segments.enumerated().filter { !$0.element.isComplete || download.totalBytes == nil }
        guard !incomplete.isEmpty else { return }

        let url = download.url
        let headers = download.requestHeaders
        let username = download.username
        let password = download.password
        let partPath = download.partFilePath
        let supportsRanges = download.supportsResume
        let totalKnown = download.totalBytes != nil
        let limiters = perDownloadLimiters()
        let settings = self.settings

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (_, segment) in incomplete {
                let segmentID = segment.id
                group.addTask { [httpClient] in
                    try await runSegment(
                        segment: segment,
                        url: url,
                        headers: headers,
                        username: username,
                        password: password,
                        partPath: partPath,
                        supportsRanges: supportsRanges,
                        totalKnown: totalKnown,
                        httpClient: httpClient,
                        limiters: limiters,
                        settings: settings,
                        onBytes: { delta in await self.recordBytes(segmentID: segmentID, delta: delta) }
                    )
                }
            }
            try await group.waitForAll()
        }
    }

    private func perDownloadLimiters() -> [BandwidthLimiter] {
        var limiters = [globalLimiter]
        if let perDownload = download.speedLimitBytesPerSecond {
            limiters.append(BandwidthLimiter(bytesPerSecond: perDownload))
        }
        return limiters
    }

    /// Apply a worker's byte delta to the authoritative record and stream throttled progress.
    private func recordBytes(segmentID: Int, delta: Int) {
        guard let index = download.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        download.segments[index].downloadedBytes = max(0, download.segments[index].downloadedBytes + Int64(delta))

        let now = clock.now
        // A negative delta is a rewind (a non-resumable segment restarting from the top): correct the
        // running total but don't feed it to the speed sampler, which only measures forward progress.
        if delta > 0 { speedSampler.add(bytes: Int64(delta), at: now) }

        if Self.seconds(from: lastEmit, to: now) >= 0.1 {
            lastEmit = now
            emit(.progress(DownloadProgress(
                id: download.id,
                downloadedBytes: download.downloadedBytes,
                totalBytes: download.totalBytes,
                bytesPerSecond: speedSampler.rate(now: now),
                segmentBytes: Dictionary(uniqueKeysWithValues: download.segments.map { ($0.id, $0.downloadedBytes) })
            )))
        }
        if Self.seconds(from: lastPersist, to: now) >= 1.0 {
            lastPersist = now
            let snapshot = download
            Task { try? await store.save(snapshot) }
        }
    }

    // MARK: Media transfer (HLS/DASH)

    /// Transfer a media plan: fetch the fMP4 init segment and any AES-128 keys, then each media
    /// segment in parallel (rate-limited, retrying on drops), decrypting as needed. Every segment
    /// lands in its own file in the `.cloakparts` directory, so an interrupted grab resumes by
    /// skipping the files already on disk — the same "disk is the source of truth" invariant the
    /// file path relies on, so it survives force-quit and reboot.
    private func transferMedia() async throws {
        guard let plan = download.mediaPlan else { return }
        let partDir = download.mediaPartDirectoryPath
        try FileManager.default.createDirectory(atPath: partDir, withIntermediateDirectories: true)
        let headers = download.requestHeaders

        // fMP4 init segment — small, fetched once and reused across a resume.
        if let initSegment = plan.initSegment {
            let path = (partDir as NSString).appendingPathComponent("init.part")
            if !FileManager.default.fileExists(atPath: path) {
                let range = initSegment.byteRange.map { $0.offset...$0.end }
                let data = try await fetchResource(url: initSegment.url, byteRange: range, headers: headers)
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }

        // AES-128 keys — usually one for the whole stream; fetch each distinct key once.
        var keys: [URL: Data] = [:]
        for keyURL in plan.keyURLs {
            keys[keyURL] = try await fetchResource(url: keyURL, byteRange: nil, headers: headers)
        }

        // Resume: whatever's already on disk is done.
        syncMediaProgressFromDisk(plan: plan, partDir: partDir)
        await persist()
        emitMediaProgress(plan: plan)

        let remaining = plan.segments.filter { !FileManager.default.fileExists(atPath: segmentPath(partDir, $0)) }
        guard !remaining.isEmpty else { return }

        let limiters = perDownloadLimiters()
        let concurrency = max(1, min(settings.maxSegmentCount, settings.defaultSegmentCount))
        let settings = self.settings

        for batch in remaining.chunked(into: concurrency) {
            try await withThrowingTaskGroup(of: Int.self) { group in
                for segment in batch {
                    let path = segmentPath(partDir, segment)
                    let key = segment.encryption.method == .aes128 ? segment.encryption.keyURL.flatMap { keys[$0] } : nil
                    group.addTask { [httpClient] in
                        try await runMediaSegment(
                            segment: segment,
                            filePath: path,
                            key: key,
                            headers: headers,
                            httpClient: httpClient,
                            limiters: limiters,
                            settings: settings,
                            onBytes: { delta in await self.recordMediaBytes(delta) }
                        )
                    }
                }
                for try await bytes in group {
                    markMediaSegmentComplete(bytes: Int64(bytes), plan: plan)
                }
            }
        }
    }

    /// Recompute completed-segment progress from the files already on disk (the resume basis).
    private func syncMediaProgressFromDisk(plan: MediaPlan, partDir: String) {
        var completed = 0
        var bytes: Int64 = 0
        for segment in plan.segments {
            if let size = fileSize(segmentPath(partDir, segment)) {
                completed += 1
                bytes += size
            }
        }
        download.mediaCompletedSegments = completed
        download.mediaDownloadedBytes = bytes
    }

    private func recordMediaBytes(_ delta: Int) {
        let now = clock.now
        speedSampler.add(bytes: Int64(delta), at: now)
        if Self.seconds(from: lastEmit, to: now) >= 0.1, let plan = download.mediaPlan {
            lastEmit = now
            emitMediaProgress(plan: plan)
        }
    }

    private func markMediaSegmentComplete(bytes: Int64, plan: MediaPlan) {
        download.mediaCompletedSegments += 1
        download.mediaDownloadedBytes += bytes
        emitMediaProgress(plan: plan)
        let now = clock.now
        // Persist less often than the file path: a media resume recomputes progress from the segment
        // files already on disk (`syncMediaProgressFromDisk`), so these snapshots only keep the
        // displayed count fresh after a force-quit — not worth re-encoding the whole (immutable,
        // possibly thousands-of-segments) `mediaPlan` every second.
        if Self.seconds(from: lastPersist, to: now) >= 5.0 {
            lastPersist = now
            let snapshot = download
            Task { try? await store.save(snapshot) }
        }
    }

    private func emitMediaProgress(plan: MediaPlan) {
        emit(.progress(DownloadProgress(
            id: download.id,
            downloadedBytes: download.mediaDownloadedBytes,
            totalBytes: nil,
            bytesPerSecond: speedSampler.rate(now: clock.now),
            completedSegments: download.mediaCompletedSegments,
            totalSegments: plan.totalSegments
        )))
    }

    /// Assemble the finished parts (init first, then each segment in order) into one file, remux it
    /// into a clean container when the remuxer can, and move the result into place — then remove the
    /// transient part directory. Concatenation alone yields a playable fMP4/TS file; the remuxer
    /// turns it into a clean, seekable `.mp4`/`.m4a` (falling back to the raw concatenation when it
    /// can't repackage the input).
    private func finalizeMedia() async throws {
        guard let plan = download.mediaPlan else { return }
        let partDir = download.mediaPartDirectoryPath

        // Concatenate into one file inside the part directory, named with a content-appropriate
        // extension so the remuxer's asset loader sniffs the right container: an fMP4 (init + `.m4s`)
        // concatenation is an MP4; otherwise keep the segments' own extension (`.ts`, `.aac`, …) so
        // raw elementary streams are recognised rather than mislabelled `.mp4`.
        let assemblyExt: String
        if plan.initSegment != nil {
            assemblyExt = "mp4"
        } else {
            let segExt = plan.segments.first?.url.pathExtension.lowercased() ?? ""
            assemblyExt = segExt.isEmpty ? "mp4" : segExt
        }
        let assemblyPath = (partDir as NSString).appendingPathComponent("assembly.\(assemblyExt)")
        try concatenateMedia(plan: plan, partDir: partDir, into: assemblyPath)

        // Remux into a clean container when possible; otherwise keep the raw concatenation.
        var sourcePath = assemblyPath
        var container = assemblyExt
        if let result = try? await remuxer.remux(sourcePath: assemblyPath) {
            sourcePath = result.outputPath
            container = result.fileExtension
        }

        // Correct the name/category to the produced container, then auto-categorize and move it in.
        download.fileName = (download.fileName as NSString).deletingPathExtension + ".\(container)"
        download.category = FileCategory.classify(fileName: download.fileName)
        if settings.autoCategorize {
            let categoryDir = (download.destinationDirectoryPath as NSString)
                .appendingPathComponent(download.category.displayName)
            download.destinationDirectoryPath = categoryDir
        }

        try SegmentedFileWriter.finalize(partPath: sourcePath, destinationPath: download.destinationFilePath)
        try? FileManager.default.removeItem(atPath: partDir)

        download.totalBytes = fileSize(download.destinationFilePath)
        download.mediaDownloadedBytes = download.totalBytes ?? download.mediaDownloadedBytes
    }

    /// Concatenate the fMP4 init segment (if any) and every media segment, in order, into a single
    /// file at `assemblyPath` (created fresh inside the part directory).
    private func concatenateMedia(plan: MediaPlan, partDir: String, into assemblyPath: String) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: partDir) {
            try fm.createDirectory(atPath: partDir, withIntermediateDirectories: true)
        }
        try? fm.removeItem(atPath: assemblyPath)
        guard fm.createFile(atPath: assemblyPath, contents: nil),
              let output = FileHandle(forWritingAtPath: assemblyPath) else {
            throw DownloadError.fileSystem(reason: "Could not open \(assemblyPath) for assembly.")
        }
        defer { try? output.close() }

        func append(_ path: String) throws {
            guard let input = FileHandle(forReadingAtPath: path) else {
                throw DownloadError.fileSystem(reason: "Missing media part \(path).")
            }
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
        }

        let initPath = (partDir as NSString).appendingPathComponent("init.part")
        if fm.fileExists(atPath: initPath) { try append(initPath) }
        for segment in plan.segments { try append(segmentPath(partDir, segment)) }
    }

    private func segmentPath(_ partDir: String, _ segment: MediaSegment) -> String {
        (partDir as NSString).appendingPathComponent("seg-\(segment.id).part")
    }

    private func fileSize(_ path: String) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
    }

    private func fetchResource(url: URL, byteRange: ClosedRange<Int64>?, headers: [String: String]) async throws -> Data {
        let (_, stream) = try await httpClient.stream(HTTPDownloadRequest(url: url, headers: headers, byteRange: byteRange))
        var data = Data()
        for try await chunk in stream { data.append(chunk) }
        return data
    }

    // MARK: Finalize

    private func finalize() async throws {
        if download.mediaPlan != nil {
            try await finalizeMedia()
            return
        }
        // For unknown-size single streams, the total is whatever we transferred.
        if download.totalBytes == nil {
            // A server that never advertised a size and then delivered zero bytes (an empty or
            // truncated response that ended without erroring) is not a real download — fail instead
            // of presenting a bogus completed 0-byte file. A genuinely empty resource advertises
            // `Content-Length: 0`, which reaches finalize with a non-nil `totalBytes` and is kept.
            guard download.downloadedBytes > 0 else {
                throw DownloadError.underlying(reason: "The server sent no data for this download.")
            }
            download.totalBytes = download.downloadedBytes
            if !download.segments.isEmpty {
                download.segments[0] = DownloadSegment(
                    id: download.segments[0].id,
                    start: 0,
                    end: max(0, download.downloadedBytes - 1),
                    downloadedBytes: download.downloadedBytes
                )
            }
        }

        // Capture the part file's location before any destination remapping.
        let partPath = download.partFilePath

        // Auto-categorization: file the finished download into a per-type subfolder.
        if settings.autoCategorize {
            let categoryDir = (download.destinationDirectoryPath as NSString)
                .appendingPathComponent(download.category.displayName)
            download.destinationDirectoryPath = categoryDir
        }

        try SegmentedFileWriter.finalize(partPath: partPath, destinationPath: download.destinationFilePath)

        // Verify against a supplied checksum, or one auto-discovered next to the download.
        let checksum = try await DownloadChecksum.resolveAndVerify(
            for: download, settings: settings, httpClient: httpClient
        )
        download.checksum = checksum.expectation
        download.checksumVerified = checksum.verified

        // Assess the code signature of installable downloads (.app/.dmg) on-device — reads the
        // signature already in the file; no network, no Gatekeeper round-trip. Best-effort: an
        // unrecognized code object records no signature rather than a misleading "unsigned".
        if settings.assessSignatures, SignatureAssessment.isAssessable(fileName: download.fileName) {
            // Validating a large bundle's seal can take a moment; run it off the actor so this task
            // stays responsive to pause/cancel while the check completes.
            let inspector = signatureInspector
            let fileURL = URL(fileURLWithPath: download.destinationFilePath)
            download.signature = await Task.detached { inspector.assess(fileURL: fileURL) }.value
        }
    }

    // MARK: Stop / persistence helpers

    private func handleStop() async -> Download {
        switch stopReason ?? .pause {
        case .cancel:
            download.status = .canceled
            SegmentedFileWriter.discardPartData(for: download)
        case .pause:
            download.status = .paused
        }
        await persist()
        emit(.downloadUpdated(download))
        return download
    }

    private func transition(to status: DownloadStatus) async {
        download.status = status
        await persist()
        emit(.downloadUpdated(download))
    }

    private func persist() async {
        try? await store.save(download)
    }

    private static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let (secs, attos) = start.duration(to: end).components
        return Double(secs) + Double(attos) / 1e18
    }

    private static func message(for error: any Error) -> String {
        (error as? DownloadError)?.userMessage ?? error.localizedDescription
    }
}
