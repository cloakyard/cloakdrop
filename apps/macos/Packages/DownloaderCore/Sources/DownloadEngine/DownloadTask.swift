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
    let store: any DownloadStore
    let globalLimiter: BandwidthLimiter
    let settings: EngineSettings
    let remuxer: any Remuxer
    let signatureInspector: any CodeSignatureInspecting
    let emit: @Sendable (EngineEvent) -> Void

    var stopReason: StopReason?
    let clock = ContinuousClock()
    var speedSampler = SpeedSampler()
    var lastEmit: ContinuousClock.Instant
    var lastPersist: ContinuousClock.Instant
    /// Chains the fire-and-forget snapshot saves so they hit the store in issue order, and so the
    /// awaited `persist()` drains them — a stale mid-transfer snapshot landing after the terminal
    /// save would mark a finished download `.downloading` and re-run it on relaunch.
    var pendingSave: Task<Void, Never>?
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
    /// Bytes claimed by a worker but not yet committed to its sparse-file range. Tail stealing reads
    /// this actor-isolated ledger so it never reassigns an interval while a disk write is in flight.
    private var segmentWriteReservations: [Int: Int64] = [:]

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

    /// Request a stop. The manager cancels this task's enclosing `Task` immediately after.
    func requestStop(_ reason: StopReason) {
        stopReason = reason
    }

    /// Run the transfer to a terminal or paused state, returning the final record.
    func run() async -> Download {
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
                try await transferSegmentsRecoveringFromInvalidRanges()
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
            download.supportsResume = head.acceptsRanges && (head.totalBytes ?? 0) > 0
            download.etag = head.etag

            if let total = head.totalBytes, total == 0 {
                // An advertised empty resource is a valid empty file. It needs no synthetic byte
                // range (there is no valid inclusive range for zero bytes), so transferSegments()
                // simply has no work and finalize moves the prepared empty part file into place.
                download.segments = []
            } else if let total = head.totalBytes, head.acceptsRanges,
                      total / max(1, settings.minimumSegmentSizeBytes) >= 2 {
                let requested = segmentCountForThisDownload(totalBytes: total)
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

    private func segmentCountForThisDownload(totalBytes: Int64) -> Int {
        SegmentPlanner.recommendedSegmentCount(
            totalBytes: totalBytes,
            requestedSegments: download.requestedSegmentCount,
            preferredSegments: settings.defaultSegmentCount,
            maximumSegments: settings.maxSegmentCount,
            minimumSegmentSize: settings.minimumSegmentSizeBytes
        )
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

    /// Range support can change behind a CDN/proxy, and some origins advertise it without honoring
    /// the actual interval. A worker reports that before writing any dubious bytes. Restart the whole
    /// resource once as a single request: slower than segmentation for this origin, but byte-safe and
    /// far more useful than exhausting retries on every nonzero segment.
    private func transferSegmentsRecoveringFromInvalidRanges() async throws {
        do {
            try await transferSegments()
        } catch let mismatch as SegmentResponseError {
            SegmentedFileWriter.discardPartData(for: download)

            if case .resourceChanged = mismatch {
                // Refresh identity/size before the clean restart. Positive evidence from a new probe
                // describes the version the following whole-body request should deliver.
                if let head = try? await httpClient.probe(HTTPDownloadRequest(
                    url: download.url,
                    headers: download.requestHeaders,
                    username: download.username,
                    password: download.password
                )) {
                    download.totalBytes = head.totalBytes
                    download.etag = head.etag
                }
            }

            download.supportsResume = false
            if let total = download.totalBytes {
                download.segments = total > 0
                    ? [DownloadSegment(id: 0, start: 0, end: total - 1)]
                    : []
            } else {
                download.segments = [DownloadSegment(id: 0, start: 0, end: Int64.max - 1)]
            }
            download.startedAt = Date()
            await persist()
            emit(.downloadUpdated(download))

            try await prepareIfNeeded()
            try await transferSegments()
        }
    }

    private func transferSegments() async throws {
        segmentWriteReservations.removeAll(keepingCapacity: true)
        let incomplete = download.segments.filter { !$0.isComplete || download.totalBytes == nil }
        guard !incomplete.isEmpty else { return }

        let sources = download.transferSources
        let headers = download.requestHeaders
        let username = download.username
        let password = download.password
        let partPath = download.partFilePath
        let supportsRanges = download.supportsResume
        let totalKnown = download.totalBytes != nil
        let expectedTotal = download.totalBytes
        let expectedETag = download.etag
        let limiters = perDownloadLimiters()
        let settings = self.settings
        // A previous run may have persisted extra tails created by work stealing. Never relaunch all
        // of them at once: keep active requests within today's configured/manual budget and feed the
        // remainder through a rolling queue.
        let connectionLimit: Int = if let total = download.totalBytes {
            min(settings.maxSegmentCount, segmentCountForThisDownload(totalBytes: total))
        } else {
            1
        }

        try await withThrowingTaskGroup(of: Int.self) { group in
            var nextPendingIndex = 0
            var activeSegmentIDs = Set<Int>()

            func spawn(_ segment: DownloadSegment) {
                let segmentID = segment.id
                activeSegmentIDs.insert(segmentID)
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
                        expectedETag: expectedETag,
                        httpClient: httpClient,
                        limiters: limiters,
                        settings: settings,
                        reserveBytes: { count in
                            await self.reserveBytes(segmentID: segmentID, requestedCount: count)
                        },
                        releaseBytes: { count in
                            await self.releaseReservedBytes(segmentID: segmentID, count: count)
                        },
                        onBytes: { delta in await self.recordBytes(segmentID: segmentID, delta: delta) }
                    )
                    return segmentID
                }
            }

            while nextPendingIndex < incomplete.count, activeSegmentIDs.count < max(1, connectionLimit) {
                spawn(incomplete[nextPendingIndex])
                nextPendingIndex += 1
            }

            // Work-stealing: as each connection finishes, hand it the unfinished tail of the segment
            // with the most bytes left, so a slow straggler doesn't leave the other connections idle
            // at the end. `stealWork` splits the victim at a point safely ahead of its write head and
            // returns the new tail; the victim learns its reduced end via its next progress callback
            // and stops there, so the two halves never overlap. Returns nil once nothing is worth
            // splitting, at which point the group simply drains.
            while let completedID = try await group.next() {
                activeSegmentIDs.remove(completedID)
                if nextPendingIndex < incomplete.count {
                    spawn(incomplete[nextPendingIndex])
                    nextPendingIndex += 1
                } else if let stolen = stealWork(among: activeSegmentIDs) {
                    spawn(stolen)
                }
            }
        }
    }

    /// Reassign a just-freed connection to the biggest remaining segment by splitting its unfetched
    /// tail into a fresh segment. Returns the new tail segment, or nil when no in-flight segment has
    /// enough left to be worth splitting (each half must clear the minimum segment size) or the
    /// transfer can't be range-resumed. Runs on the actor, so it observes a consistent segment table.
    private func stealWork(among activeSegmentIDs: Set<Int>) -> DownloadSegment? {
        // Only a range-resumable, known-size transfer can be safely re-split; an open-ended or
        // non-resumable stream has no offsets to divide.
        guard download.supportsResume, download.totalBytes != nil else { return nil }
        // Bound the segment table so a pathological download can't split without end.
        guard download.segments.count < 4 * settings.maxSegmentCount else { return nil }

        // A worthwhile split leaves both halves at or above the minimum segment size; the resulting
        // gap between the victim's write head and the split point (≥ half the remaining bytes) also
        // dwarfs the sub-chunk lag in the victim's reported progress, so the halves can't overlap.
        let minimum = max(1, settings.minimumSegmentSizeBytes)
        var victimIndex: Int?
        var mostRemaining: Int64 = 0
        for (index, segment) in download.segments.enumerated() where activeSegmentIDs.contains(segment.id) {
            let reserved = segmentWriteReservations[segment.id] ?? 0
            let reservedOffset = segment.currentOffset + reserved
            let remaining = segment.end - reservedOffset + 1
            if remaining / 2 >= minimum, remaining > mostRemaining {
                victimIndex = index
                mostRemaining = remaining
            }
        }
        guard let victimIndex else { return nil }

        let victim = download.segments[victimIndex]
        let reserved = segmentWriteReservations[victim.id] ?? 0
        let reservedOffset = victim.currentOffset + reserved
        let mid = reservedOffset + (victim.end - reservedOffset + 1) / 2
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

    /// Atomically claim a writable prefix against the latest segment boundary. Claimed bytes count
    /// as unavailable to work stealing but do not become persisted progress until `recordBytes` runs
    /// after the file write succeeds.
    private func reserveBytes(segmentID: Int, requestedCount: Int) -> SegmentWriteReservation {
        guard requestedCount > 0,
              let index = download.segments.firstIndex(where: { $0.id == segmentID }) else {
            return SegmentWriteReservation(byteCount: 0, end: .max)
        }
        let segment = download.segments[index]
        let alreadyReserved = segmentWriteReservations[segmentID] ?? 0
        let available = max(0, segment.remainingBytes - alreadyReserved)
        let allowed = min(Int64(requestedCount), available)
        if allowed > 0 {
            segmentWriteReservations[segmentID] = alreadyReserved + allowed
        }
        return SegmentWriteReservation(byteCount: Int(allowed), end: segment.end)
    }

    private func releaseReservedBytes(segmentID: Int, count: Int) {
        guard count > 0 else { return }
        let remaining = max(0, (segmentWriteReservations[segmentID] ?? 0) - Int64(count))
        segmentWriteReservations[segmentID] = remaining == 0 ? nil : remaining
    }

    /// Apply a worker's byte delta to the authoritative record and stream throttled progress, then
    /// return the segment's current end offset — which work-stealing may have shrunk since the worker
    /// last checked, telling it to stop early. `Int64.max` for an unknown segment id means "keep going".
    private func recordBytes(segmentID: Int, delta: Int) -> Int64 {
        guard let index = download.segments.firstIndex(where: { $0.id == segmentID }) else { return .max }
        if delta > 0 {
            releaseReservedBytes(segmentID: segmentID, count: delta)
        }
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

}
