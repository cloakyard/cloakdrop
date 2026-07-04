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
    private(set) var download: Download
    private let httpClient: any HTTPClient
    private let store: any DownloadStore
    private let globalLimiter: BandwidthLimiter
    let settings: EngineSettings
    private let remuxer: any Remuxer
    private let signatureInspector: any CodeSignatureInspecting
    private let emit: @Sendable (EngineEvent) -> Void

    private var stopReason: StopReason?
    private let clock = ContinuousClock()
    private var speedSampler = SpeedSampler()
    private var lastEmit: ContinuousClock.Instant
    private var lastPersist: ContinuousClock.Instant
    /// Timestamp of the last forward-progress sample, for accumulating active-transfer time.
    private var lastStatSample: ContinuousClock.Instant?
    /// Live byte tallies of the *in-flight* media segments (keyed by part-file path) — the
    /// mid-segment progress the completed count can't see, so a paired grab whose whole video is
    /// one segment still shows moving bytes. Entries clear as their segments complete.
    private var mediaInflight: [String: Int64] = [:]
    /// Expected size per media segment (keyed by part-file path), reported by workers from the
    /// response head / seeded from completed files on disk. Once every segment is present the sum
    /// becomes the grab's byte total, giving the UI a real fraction and ETA.
    private var mediaExpected: [String: Int64] = [:]

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

    private func perDownloadLimiters() -> [BandwidthLimiter] {
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
            let snapshot = download
            Task { try? await store.save(snapshot) }
        }
        return download.segments[index].end
    }

    // MARK: Media transfer (HLS/DASH)

    /// Transfer a media plan: fetch the fMP4 init segment and any AES-128 keys, then each media
    /// segment in parallel (rate-limited, retrying on drops), decrypting as needed. Every segment
    /// lands in its own file in the `.cdparts` directory, so an interrupted grab resumes by
    /// skipping the files already on disk — the same "disk is the source of truth" invariant the
    /// file path relies on, so it survives force-quit and reboot.
    private func transferMedia() async throws {
        guard let plan = download.mediaPlan else { return }
        let partDir = download.mediaPartDirectoryPath
        try FileManager.default.createDirectory(atPath: partDir, withIntermediateDirectories: true)
        let headers = download.requestHeaders

        // fMP4 init segments — small, fetched once and reused across a resume. A separate audio stream
        // has its own init.
        try await fetchInitIfNeeded(plan.initSegment, named: "init.part", partDir: partDir, headers: headers)
        if plan.hasSeparateAudio {
            try await fetchInitIfNeeded(plan.audioInitSegment, named: "audio-init.part", partDir: partDir, headers: headers)
        }

        // AES-128 keys across video + audio — usually one for the whole stream; fetch each once.
        var keys: [URL: Data] = [:]
        for keyURL in plan.keyURLs {
            keys[keyURL] = try await fetchResource(url: keyURL, byteRange: nil, headers: headers)
        }

        // Resume: whatever's already on disk is done.
        syncMediaProgressFromDisk(plan: plan, partDir: partDir)
        await persist()
        emitMediaProgress(plan: plan)

        // One work list over the video (or muxed) segments and any separate audio segments; each
        // lands in its own file, so an interrupted grab resumes by skipping what's already there.
        let remaining = mediaWorkItems(plan: plan, partDir: partDir)
            .filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard !remaining.isEmpty else { return }

        let limiters = perDownloadLimiters()
        let concurrency = max(1, min(settings.maxSegmentCount, settings.defaultSegmentCount))
        let settings = self.settings

        for batch in remaining.chunked(into: concurrency) {
            try await withThrowingTaskGroup(of: (String, Int).self) { group in
                for item in batch {
                    let path = item.path
                    let segment = item.segment
                    let key = segment.encryption.method == .aes128 ? segment.encryption.keyURL.flatMap { keys[$0] } : nil
                    group.addTask { [httpClient] in
                        let bytes = try await runMediaSegment(
                            segment: segment,
                            filePath: path,
                            key: key,
                            headers: headers,
                            httpClient: httpClient,
                            limiters: limiters,
                            settings: settings,
                            onExpectedBytes: { total in await self.recordMediaExpected(path: path, bytes: total) },
                            onBytes: { delta in await self.recordMediaBytes(path: path, delta: delta) }
                        )
                        return (path, bytes)
                    }
                }
                for try await (path, bytes) in group {
                    markMediaSegmentComplete(path: path, bytes: Int64(bytes), plan: plan)
                }
            }
        }
    }

    /// One downloadable unit: a segment and the file it lands in. Video and audio share this list so
    /// the transfer, resume, and progress logic treat both streams uniformly.
    private struct MediaWorkItem { let segment: MediaSegment; let path: String }

    /// Every segment to fetch for a plan — the video (or muxed) segments plus any separate audio —
    /// each mapped to its own on-disk part file (audio in a distinct `audio-` namespace).
    private func mediaWorkItems(plan: MediaPlan, partDir: String) -> [MediaWorkItem] {
        var items = plan.segments.map { MediaWorkItem(segment: $0, path: segmentPath(partDir, $0)) }
        for segment in (plan.audioSegments ?? []) {
            items.append(MediaWorkItem(segment: segment, path: audioSegmentPath(partDir, segment)))
        }
        return items
    }

    /// Fetch an fMP4 init segment into `named` under the part dir, unless it's already there (resume).
    private func fetchInitIfNeeded(
        _ initSegment: MediaInitSegment?, named: String, partDir: String, headers: [String: String]
    ) async throws {
        guard let initSegment else { return }
        let path = (partDir as NSString).appendingPathComponent(named)
        guard !FileManager.default.fileExists(atPath: path) else { return }
        let range = initSegment.byteRange.map { $0.offset...$0.end }
        let data = try await fetchResource(url: initSegment.url, byteRange: range, headers: headers)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Recompute completed-segment progress from the files already on disk (the resume basis) —
    /// counting video and audio parts alike.
    private func syncMediaProgressFromDisk(plan: MediaPlan, partDir: String) {
        var completed = 0
        var bytes: Int64 = 0
        mediaInflight = [:]
        mediaExpected = [:]
        for item in mediaWorkItems(plan: plan, partDir: partDir) {
            if let size = fileSize(item.path) {
                completed += 1
                bytes += size
                mediaExpected[item.path] = size   // a finished file *is* its expected size
            }
        }
        download.mediaCompletedSegments = completed
        download.mediaDownloadedBytes = bytes
    }

    /// Record a worker's transfer delta for one segment. A negative delta retracts bytes a restart
    /// discarded (a refused resume) — it adjusts the in-flight tally without polluting the speed
    /// stats. The tally from a *previous* run's partial isn't counted here (it was never added), so
    /// the clamp to zero keeps a retraction from bleeding into other segments' bytes.
    private func recordMediaBytes(path: String, delta: Int) {
        guard delta >= 0 else {
            mediaInflight[path] = max(0, (mediaInflight[path] ?? 0) + Int64(delta))
            return
        }
        mediaInflight[path, default: 0] += Int64(delta)
        let now = clock.now
        speedSampler.add(bytes: Int64(delta), at: now)
        recordStats(at: now)
        if Self.seconds(from: lastEmit, to: now) >= 0.1, let plan = download.mediaPlan {
            lastEmit = now
            emitMediaProgress(plan: plan)
        }
    }

    /// Record a segment's expected size (from its response head) — see `mediaExpected`.
    private func recordMediaExpected(path: String, bytes: Int64) {
        mediaExpected[path] = bytes
    }

    /// Update the peak-rate and active-transfer-time stats from the current sample. Called only on
    /// forward progress. Active time ignores gaps ≥ 2s (a stall or pause), so the average reflects
    /// real transfer speed rather than wall-clock elapsed.
    private func recordStats(at now: ContinuousClock.Instant) {
        let rate = speedSampler.rate(now: now)
        if rate > (download.peakBytesPerSecond ?? 0) { download.peakBytesPerSecond = rate }
        if let last = lastStatSample {
            let gap = Self.seconds(from: last, to: now)
            if gap > 0, gap < 2.0 { download.activeSeconds = (download.activeSeconds ?? 0) + gap }
        }
        lastStatSample = now
    }

    private func markMediaSegmentComplete(path: String, bytes: Int64, plan: MediaPlan) {
        download.mediaCompletedSegments += 1
        download.mediaDownloadedBytes += bytes
        mediaInflight[path] = nil                 // its bytes now live in the completed tally
        mediaExpected[path] = bytes               // the actual size is authoritative
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
        // Live bytes include the in-flight segments; the total appears once every segment's size is
        // known (immediately for a paired grab, whose 1–2 segments all start at once) — giving the
        // UI a byte-accurate bar and ETA instead of a frozen "0 of 2 segments".
        let inflight = mediaInflight.values.reduce(0, +)
        let totalBytes: Int64? = mediaExpected.count == plan.totalSegments
            ? mediaExpected.values.reduce(0, +)
            : nil
        emit(.progress(DownloadProgress(
            id: download.id,
            downloadedBytes: download.mediaDownloadedBytes + inflight,
            totalBytes: totalBytes,
            bytesPerSecond: speedSampler.rate(now: clock.now),
            peakBytesPerSecond: download.peakBytesPerSecond ?? 0,
            averageBytesPerSecond: download.averageBytesPerSecond ?? 0,
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

        // Assemble the video (or muxed) stream by concatenating its init + segments into one file,
        // named with a content-appropriate extension so the remuxer's asset loader sniffs the right
        // container: an fMP4 (init + `.m4s`) concatenation is an MP4; otherwise keep the segments'
        // own extension (`.ts`, `.aac`, …) so raw elementary streams aren't mislabelled `.mp4`.
        let videoExt = assemblyExtension(initSegment: plan.initSegment, segments: plan.segments)
        let videoAssembly = (partDir as NSString).appendingPathComponent("assembly.\(videoExt)")
        try concatenate(initNamed: "init.part", segments: plan.segments,
                        pathFor: { segmentPath(partDir, $0) }, partDir: partDir, into: videoAssembly)

        var sourcePath = videoAssembly
        var container = videoExt
        if plan.hasSeparateAudio {
            // Assemble the separate audio stream and mux it into the video so the result has sound.
            let audioSegs = plan.audioSegments ?? []
            let audioExt = assemblyExtension(initSegment: plan.audioInitSegment, segments: audioSegs)
            let audioAssembly = (partDir as NSString).appendingPathComponent("assembly-audio.\(audioExt)")
            try concatenate(initNamed: "audio-init.part", segments: audioSegs,
                            pathFor: { audioSegmentPath(partDir, $0) }, partDir: partDir, into: audioAssembly)
            if let muxed = try? await remuxer.mux(videoPath: videoAssembly, audioPath: audioAssembly) {
                sourcePath = muxed.outputPath
                container = muxed.fileExtension
            } else if let result = try? await remuxer.remux(sourcePath: videoAssembly) {
                // Muxing these codecs isn't supported (e.g. VP9/Opus without the ffmpeg backend): ship
                // a clean video-only file rather than fail the whole grab.
                sourcePath = result.outputPath
                container = result.fileExtension
            }
        } else if let result = try? await remuxer.remux(sourcePath: videoAssembly) {
            // Single muxed stream — repackage into a clean container when possible.
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

        if settings.applyQuarantine {
            Quarantine.apply(toPath: download.destinationFilePath,
                             sourceURL: download.url,
                             originURL: download.requestHeaders["Referer"].flatMap(URL.init(string:)))
        }

        download.totalBytes = fileSize(download.destinationFilePath)
        download.mediaDownloadedBytes = download.totalBytes ?? download.mediaDownloadedBytes
    }

    /// The container extension for a concatenation: `mp4` for an fMP4 stream (has an init segment),
    /// else the segments' own extension (`.ts`, `.aac`, …) so raw elementary streams aren't
    /// mislabelled and the remuxer's loader sniffs the right container.
    private func assemblyExtension(initSegment: MediaInitSegment?, segments: [MediaSegment]) -> String {
        if initSegment != nil { return "mp4" }
        let ext = segments.first?.url.pathExtension.lowercased() ?? ""
        return ext.isEmpty ? "mp4" : ext
    }

    /// Concatenate an init segment (named file, if present) and every segment, in order, into a
    /// single file at `assemblyPath`. `pathFor` maps a segment to its on-disk part file, so the same
    /// routine assembles both the video and the separate audio stream.
    private func concatenate(
        initNamed initName: String, segments: [MediaSegment],
        pathFor: (MediaSegment) -> String, partDir: String, into assemblyPath: String
    ) throws {
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

        let initPath = (partDir as NSString).appendingPathComponent(initName)
        if fm.fileExists(atPath: initPath) { try append(initPath) }
        for segment in segments { try append(pathFor(segment)) }
    }

    private func segmentPath(_ partDir: String, _ segment: MediaSegment) -> String {
        (partDir as NSString).appendingPathComponent("seg-\(segment.id).part")
    }

    /// Audio part files live in a distinct namespace so an audio segment can't collide with a video
    /// segment that happens to share its media-sequence id.
    private func audioSegmentPath(_ partDir: String, _ segment: MediaSegment) -> String {
        (partDir as NSString).appendingPathComponent("audio-\(segment.id).part")
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
