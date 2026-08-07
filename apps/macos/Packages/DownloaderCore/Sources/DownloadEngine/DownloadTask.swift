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
    var download: Download
    let httpClient: any HTTPClient
    private let store: any DownloadStore
    private let globalLimiter: BandwidthLimiter
    let settings: EngineSettings
    let remuxer: any Remuxer
    private let signatureInspector: any CodeSignatureInspecting
    let emit: @Sendable (EngineEvent) -> Void

    private var stopReason: StopReason?
    let clock = ContinuousClock()
    var speedSampler = SpeedSampler()
    var lastEmit: ContinuousClock.Instant
    var lastPersist: ContinuousClock.Instant
    /// Chains the fire-and-forget snapshot saves so they hit the store in issue order, and so the
    /// awaited `persist()` drains them — a stale mid-transfer snapshot landing after the terminal
    /// save would mark a finished download `.downloading` and re-run it on relaunch.
    private var pendingSave: Task<Void, Never>?
    /// Timestamp of the last forward-progress sample, for accumulating active-transfer time.
    var lastStatSample: ContinuousClock.Instant?
    /// Live byte tallies of the *in-flight* media segments (keyed by part-file path) — the
    /// mid-segment progress the completed count can't see, so a paired grab whose whole video is
    /// one segment still shows moving bytes. Entries clear as their segments complete.
    var mediaInflight: [String: Int64] = [:]
    /// Expected size per media segment (keyed by part-file path), reported by workers from the
    /// response head / seeded from completed files on disk. Once every segment is present the sum
    /// becomes the grab's byte total, giving the UI a real fraction and ETA.
    var mediaExpected: [String: Int64] = [:]

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
        // Resuming a partial download whose part file can no longer back the persisted segment
        // offsets — deleted, moved, on a now-unmounted volume, or orphaned by a part-file format
        // change (e.g. a `.cloakpart` left behind when the extension became `.cdpart`) — would seek
        // past the end of a freshly created, zero-filled file and stitch garbage into the output.
        // Detect that up front, before any network probe, and restart cleanly from scratch.
        if !download.segments.isEmpty, download.downloadedBytes > 0, !partFileBacksProgress() {
            SegmentedFileWriter.discardPartData(for: download)
            download.segments = []
            download.startedAt = Date()
            await persist()
            emit(.downloadUpdated(download))
        }

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
            // Probe mirrors best-first, falling over to the next when one is unreachable, so a dead
            // primary doesn't sink a download that other Metalink mirrors could serve. (Single-source
            // downloads just probe their one URL.)
            var probed: HTTPResponseHead?
            var probeError: Error?
            for source in download.transferSources {
                do {
                    probed = try await httpClient.probe(
                        HTTPDownloadRequest(
                            url: source,
                            headers: download.requestHeaders,
                            username: download.username,
                            password: download.password
                        )
                    )
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    probeError = error
                }
            }
            guard let head = probed else { throw probeError ?? DownloadError.networkLost }
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
        // Fail early if the destination volume can't hold the bytes still to be written, rather than
        // filling the disk and erroring out mid-transfer.
        if let total = download.totalBytes {
            let remaining = max(0, total - download.downloadedBytes)
            let available = (try? URL(fileURLWithPath: download.destinationDirectoryPath)
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
            if DiskSpace.isInsufficient(needed: remaining, available: available) {
                throw DownloadError.insufficientDiskSpace(needed: remaining, available: available ?? 0)
            }
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

    /// True when the `.cdpart` file on disk can actually back the segments' persisted progress: it
    /// exists and is at least large enough to hold the highest byte any segment claims to have
    /// written (`start + downloadedBytes`). False means those bytes are gone — the part file was
    /// deleted, moved, left on an unmounted volume, or orphaned by a format change — so resuming
    /// from the persisted offsets would read zeros. Callers restart cleanly when this is false.
    private func partFileBacksProgress() -> Bool {
        let highestWrittenOffset = download.segments.reduce(Int64(0)) { highest, segment in
            segment.downloadedBytes > 0 ? max(highest, segment.start + segment.downloadedBytes) : highest
        }
        guard highestWrittenOffset > 0 else { return true }   // no progress claimed ⇒ nothing to back
        let attributes = try? FileManager.default.attributesOfItem(atPath: download.partFilePath)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return size >= highestWrittenOffset
    }

    // MARK: Transfer

    private func transferSegments() async throws {
        let incomplete = download.segments.enumerated().filter { !$0.element.isComplete || download.totalBytes == nil }
        guard !incomplete.isEmpty else { return }

        let sources = download.transferSources
        let headers = download.requestHeaders
        let username = download.username
        let password = download.password
        let partPath = download.partFilePath
        let supportsRanges = download.supportsResume
        let totalKnown = download.totalBytes != nil
        let expectedTotal = download.totalBytes
        let limiters = perDownloadLimiters()
        let settings = self.settings

        try await withThrowingTaskGroup(of: Void.self) { group in
            func spawn(_ segment: DownloadSegment) {
                let segmentID = segment.id
                group.addTask { [httpClient] in
                    try await runSegment(
                        segment: segment,
                        sources: sources,
                        mirrorStart: segmentID,
                        headers: headers,
                        username: username,
                        password: password,
                        partPath: partPath,
                        supportsRanges: supportsRanges,
                        totalKnown: totalKnown,
                        expectedTotal: expectedTotal,
                        httpClient: httpClient,
                        limiters: limiters,
                        settings: settings,
                        onBytes: { delta in await self.recordBytes(segmentID: segmentID, delta: delta) }
                    )
                }
            }

            for (_, segment) in incomplete { spawn(segment) }

            // Work-stealing: as each connection finishes, hand it the unfinished tail of the segment
            // with the most bytes left, so a slow straggler doesn't leave the other connections idle
            // at the end. `stealWork` splits the victim at a point safely ahead of its write head and
            // returns the new tail; the victim learns its reduced end via its next progress callback
            // and stops there, so the two halves never overlap. Returns nil once nothing is worth
            // splitting, at which point the group simply drains.
            while try await group.next() != nil {
                if let stolen = stealWork() { spawn(stolen) }
            }
        }
    }

    /// Reassign a just-freed connection to the biggest remaining segment by splitting its unfetched
    /// tail into a fresh segment. Returns the new tail segment, or nil when no in-flight segment has
    /// enough left to be worth splitting (each half must clear the minimum segment size) or the
    /// transfer can't be range-resumed. Runs on the actor, so it observes a consistent segment table.
    private func stealWork() -> DownloadSegment? {
        // Only a range-resumable, known-size transfer can be safely re-split; an open-ended or
        // non-resumable stream has no offsets to divide.
        guard download.supportsResume, download.totalBytes != nil else { return nil }
        // Bound the segment table so a pathological download can't split without end.
        guard download.segments.count < 4 * settings.maxSegmentCount else { return nil }

        // A worthwhile split leaves both halves at or above the minimum segment size; the resulting
        // gap between the victim's write head and the split point (≥ half the remaining bytes) also
        // dwarfs the sub-chunk lag in the victim's reported progress, so the halves can't overlap.
        let minRemaining = 2 * settings.minimumSegmentSizeBytes
        var victimIndex: Int?
        var mostRemaining: Int64 = 0
        for (index, segment) in download.segments.enumerated() {
            let remaining = segment.end - segment.currentOffset + 1
            if remaining >= minRemaining, remaining > mostRemaining {
                victimIndex = index
                mostRemaining = remaining
            }
        }
        guard let victimIndex else { return nil }

        let victim = download.segments[victimIndex]
        let mid = victim.currentOffset + (victim.end - victim.currentOffset + 1) / 2
        let oldEnd = victim.end
        // Shrink the victim to [start, mid]; the freed worker takes the tail [mid + 1, oldEnd].
        download.segments[victimIndex] = DownloadSegment(
            id: victim.id, start: victim.start, end: mid, downloadedBytes: victim.downloadedBytes
        )
        let tail = DownloadSegment(id: nextSegmentID(), start: mid + 1, end: oldEnd, downloadedBytes: 0)
        download.segments.append(tail)
        return tail
    }

    /// A fresh, unused segment id (ids only ever grow, so splits never collide with existing ones).
    private func nextSegmentID() -> Int { (download.segments.map(\.id).max() ?? -1) + 1 }

    func perDownloadLimiters() -> [BandwidthLimiter] {
        var limiters = [globalLimiter]
        if let perDownload = download.speedLimitBytesPerSecond {
            limiters.append(BandwidthLimiter(bytesPerSecond: perDownload))
        }
        return limiters
    }

    /// Apply a worker's byte delta to the authoritative record and stream throttled progress, then
    /// return the segment's current end offset — which work-stealing may have shrunk since the worker
    /// last checked, telling it to stop early. `Int64.max` for an unknown segment id means "keep going".
    private func recordBytes(segmentID: Int, delta: Int) -> Int64 {
        guard let index = download.segments.firstIndex(where: { $0.id == segmentID }) else { return .max }
        download.segments[index].downloadedBytes = max(0, download.segments[index].downloadedBytes + Int64(delta))

        let now = clock.now
        // A negative delta is a rewind (a non-resumable segment restarting from the top): correct the
        // running total but don't feed it to the speed sampler, which only measures forward progress.
        if delta > 0 {
            speedSampler.add(bytes: Int64(delta), at: now)
            recordStats(at: now)
        }

        if Self.seconds(from: lastEmit, to: now) >= 0.1 {
            lastEmit = now
            emit(.progress(DownloadProgress(
                id: download.id,
                downloadedBytes: download.downloadedBytes,
                totalBytes: download.totalBytes,
                bytesPerSecond: speedSampler.rate(now: now),
                peakBytesPerSecond: download.peakBytesPerSecond ?? 0,
                averageBytesPerSecond: download.averageBytesPerSecond ?? 0,
                segmentBytes: Dictionary(uniqueKeysWithValues: download.segments.map { ($0.id, $0.downloadedBytes) })
            )))
        }
        if Self.seconds(from: lastPersist, to: now) >= 1.0 {
            lastPersist = now
            enqueueSave(download)
        }
        return download.segments[index].end
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

        // Stamp it like a browser download so Gatekeeper vets it on first open.
        if settings.applyQuarantine {
            Quarantine.apply(toPath: download.destinationFilePath,
                             sourceURL: download.url,
                             originURL: download.requestHeaders["Referer"].flatMap(URL.init(string:)))
        }

        // Verify against a supplied checksum, or one auto-discovered next to the download.
        let checksum = try await DownloadChecksum.resolveAndVerify(
            for: download, settings: settings, httpClient: httpClient
        )
        download.checksum = checksum.expectation
        download.checksumVerified = checksum.verified

        // Extract only AFTER integrity is established — never unpack an archive whose checksum failed.
        await autoExtractIfArchive()

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

        if settings.generateProvenanceReceipts {
            download.provenance = await buildProvenanceReceipt(precomputedSHA256: checksum.sha256)
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

    /// Persist a throttled mid-transfer snapshot after any save already queued (fire-and-forget).
    func enqueueSave(_ snapshot: Download) {
        pendingSave = Task { [store, previous = pendingSave] in
            await previous?.value
            try? await store.save(snapshot)
        }
    }

    func persist() async {
        enqueueSave(download)
        await pendingSave?.value
    }

    static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        start.seconds(to: end)
    }

    private static func message(for error: any Error) -> String {
        (error as? DownloadError)?.userMessage ?? error.localizedDescription
    }
}
