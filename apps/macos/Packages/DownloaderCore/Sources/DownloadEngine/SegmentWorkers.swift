import Foundation
import DownloadModels

// The concurrent segment workers that `DownloadTask` fans out. They're free functions (not
// actor-isolated) so many can run at once, reporting byte deltas back through the actor via `onBytes`.

// MARK: - File segment worker

/// Transfer one segment's remaining bytes into the part file, retrying with backoff and
/// resuming from the current offset on transient failures. Honors pause/cancel via task
/// cancellation. Returns when the segment is complete (or the open-ended stream ends).
func runSegment(
    segment: DownloadSegment,
    sources: [URL],
    mirrorStart: Int,
    headers: [String: String],
    username: String?,
    password: String?,
    partPath: String,
    supportsRanges: Bool,
    totalKnown: Bool,
    expectedTotal: Int64?,
    httpClient: any HTTPClient,
    limiters: [BandwidthLimiter],
    settings: EngineSettings,
    onBytes: @Sendable (Int) async -> Int64
) async throws {
    var local = segment
    // The authoritative end offset, refreshed from every progress report. Work-stealing can shrink
    // it mid-transfer when another connection claims this segment's tail, at which point this worker
    // stops early at the new boundary. `end` on the value-type snapshot never changes.
    var currentEnd = segment.end
    var attempt = 0
    var progressMark = local.currentOffset
    // Which mirror this worker pulls from. It starts at `mirrorStart` (segments are seeded at
    // different offsets so they spread across mirrors for parallel throughput) and advances on every
    // failure, so a dead or throttling mirror is abandoned for the next one. `% sources.count` wraps.
    var sourceIndex = mirrorStart

    while true {
        try Task.checkCancellation()
        if totalKnown && local.currentOffset > currentEnd { return }   // done (possibly via a stolen tail)

        let canResume = supportsRanges && totalKnown
        // A server without range support replays the whole body from byte 0 on every (re)connection,
        // so any bytes already written for this segment are stale. Rewind to the segment start and
        // correct the reported total before reopening the handle — otherwise a retry after a drop
        // (or a resume of a paused non-resumable download) writes byte-0 data at the advanced offset
        // and silently corrupts the file.
        if !canResume && local.downloadedBytes > 0 {
            currentEnd = await onBytes(-Int(local.downloadedBytes))
            local.downloadedBytes = 0
        }

        let range: ClosedRange<Int64>? = canResume ? (local.currentOffset...currentEnd) : nil
        let url = sources[sourceIndex % sources.count]
        do {
            let request = HTTPDownloadRequest(url: url, headers: headers, byteRange: range, username: username, password: password)
            let (head, stream) = try await httpClient.stream(request)
            // Reject an untrustworthy mirror before writing a byte, failing over to the next source
            // (see `mirrorServesThisSegment`). A Metalink mirror was never probed, so its range support
            // and identity must be checked here rather than assumed from the download-level probe.
            guard mirrorServesThisSegment(head: head, requestedRange: range,
                                          offset: local.currentOffset, expectedTotal: expectedTotal) else {
                throw DownloadError.networkLost
            }
            let handle = try SegmentFileHandle(partPath: partPath, startingAtOffset: local.currentOffset)
            defer { handle.close() }

            for try await chunk in stream {
                try Task.checkCancellation()
                if chunk.isEmpty { continue }

                // Trim to what this segment still needs; nil means its tail was stolen — stop writing.
                guard let data = capToSegment(chunk, totalKnown: totalKnown, supportsRanges: supportsRanges,
                                              offset: local.currentOffset, end: currentEnd) else { break }
                for limiter in limiters where limiter.isLimited {
                    await limiter.awaitAllowance(byteCount: data.count)
                }
                try handle.write(data)
                local.downloadedBytes += Int64(data.count)
                currentEnd = await onBytes(data.count)           // report progress; learn our (maybe shrunk) end

                if totalKnown && supportsRanges && local.currentOffset > currentEnd { break }
            }
            handle.synchronize()

            if !totalKnown { return }                             // open-ended stream finished
            if local.currentOffset > currentEnd { return }        // segment complete (up to its current end)
            // Stream ended before the segment completed — treat as a drop and resume.
            throw DownloadError.networkLost
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            sourceIndex += 1   // failover: the next attempt pulls from the next mirror (no-op if single-source)
            // Never give up before every mirror has been tried at least once: a late-but-live source
            // shouldn't be abandoned because earlier ones were dead. A working mirror still resets the
            // budget on progress (below), so a long, repeatedly-dropping transfer isn't killed early.
            try await accountRetry(error: error, attempt: &attempt, progressMark: &progressMark,
                                   progress: local.currentOffset, settings: settings,
                                   maxAttempts: max(settings.maxRetryAttempts, sources.count - 1))
        }
    }
}

/// Whether a mirror's response can back *this* ranged segment, checked before any byte is written: a
/// non-206 answer to an offset request means the mirror ignored our `Range` and is replaying the whole
/// body from byte 0 (which would corrupt a mid-file segment), and a differing advertised total means
/// it's serving a different file. Either way the caller fails over to another source. The optional
/// whole-file checksum is only a last-resort backstop for anything that slips past this.
private func mirrorServesThisSegment(
    head: HTTPResponseHead, requestedRange: ClosedRange<Int64>?, offset: Int64, expectedTotal: Int64?
) -> Bool {
    if requestedRange != nil, head.statusCode != 206, offset > 0 { return false }
    if let expectedTotal, let advertised = head.totalBytes, advertised != expectedTotal { return false }
    return true
}

/// Trim an arriving chunk to the bytes this segment still needs. Returns `nil` when nothing remains —
/// work-stealing may have handed this segment's tail to another connection, shrinking its end. Only a
/// bounded, range-backed transfer caps; an open-ended stream of unknown size writes every chunk whole.
private func capToSegment(_ chunk: Data, totalKnown: Bool, supportsRanges: Bool, offset: Int64, end: Int64) -> Data? {
    guard totalKnown, supportsRanges else { return chunk }
    let remaining = end - offset + 1
    if remaining <= 0 { return nil }
    return Int64(chunk.count) > remaining ? chunk.prefix(Int(remaining)) : chunk
}

/// Shared retry accounting for both segment workers: count the attempt, but reset the budget whenever
/// the transfer advanced past `progressMark` — so `maxRetryAttempts` counts *consecutive stalled*
/// attempts, and a long, repeatedly-dropping transfer isn't killed while it's still making headway.
func accountRetry(
    error: any Error, attempt: inout Int, progressMark: inout Int64, progress: Int64,
    settings: EngineSettings, maxAttempts: Int? = nil
) async throws {
    attempt += 1
    if progress > progressMark { attempt = 0; progressMark = progress }
    try await backoffOrThrow(attempt: attempt, settings: settings, lastError: error,
                             maxAttempts: maxAttempts ?? settings.maxRetryAttempts)
}

/// Sleep with jittered backoff before the next retry, or throw `retriesExhausted` once the attempt
/// budget is spent. `maxAttempts` lets the multi-source file worker guarantee a full mirror sweep
/// (≥ `sources.count - 1`) independent of the user's transient-drop retry setting.
private func backoffOrThrow(attempt: Int, settings: EngineSettings, lastError: any Error, maxAttempts: Int) async throws {
    guard attempt <= maxAttempts else {
        throw DownloadError.retriesExhausted(lastReason: failureMessage(lastError))
    }
    let delay = BackoffPolicy.jittered(
        attempt: attempt,
        base: settings.retryBaseDelaySeconds,
        maximum: settings.retryMaxDelaySeconds
    )
    try await Task.sleep(for: .seconds(delay))
}

private func failureMessage(_ error: any Error) -> String {
    (error as? DownloadError)?.userMessage ?? error.localizedDescription
}

extension Array {
    /// Split into consecutive chunks of at most `size` — used to bound media segment concurrency.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
