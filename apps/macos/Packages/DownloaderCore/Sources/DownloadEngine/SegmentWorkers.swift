import Foundation
import DownloadModels

// The concurrent segment workers that `DownloadTask` fans out. They're free functions (not
// actor-isolated) so many can run at once, reporting byte deltas back through the actor via `onBytes`.

/// A response-level invariant failed before any bytes were accepted. The enclosing DownloadTask can
/// safely discard the sparse part file and retry as one whole stream rather than stitching dubious
/// ranges together.
enum SegmentResponseError: Error, Sendable {
    case rangeNotHonored
    case resourceChanged
}

/// A two-phase claim on the next bytes a segment may write. The DownloadTask actor reserves this
/// interval before disk I/O, so work stealing can never split through a chunk already in flight.
struct SegmentWriteReservation: Sendable {
    let byteCount: Int
    let end: Int64
}

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
    expectedETag: String?,
    httpClient: any HTTPClient,
    limiters: [BandwidthLimiter],
    settings: EngineSettings,
    reserveBytes: @Sendable (Int) async -> SegmentWriteReservation,
    releaseBytes: @Sendable (Int) async -> Void,
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
    var consecutiveValidationFailures = 0
    var consecutivePermanentSourceFailures = 0
    var lifetimeFailures = 0

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
            let stream = try await openValidatedSegmentStream(
                url: url,
                primaryURL: sources.first,
                headers: headers,
                range: range,
                username: username,
                password: password,
                expectedTotal: expectedTotal,
                expectedETag: expectedETag,
                httpClient: httpClient
            )
            consecutiveValidationFailures = 0
            consecutivePermanentSourceFailures = 0
            try await transferSegmentBody(
                stream: stream,
                local: &local,
                currentEnd: &currentEnd,
                requestedRange: range,
                partPath: partPath,
                supportsRanges: supportsRanges,
                totalKnown: totalKnown,
                limiters: limiters,
                reserveBytes: reserveBytes,
                releaseBytes: releaseBytes,
                onBytes: onBytes
            )
            return
        } catch is CancellationError {
            throw CancellationError()
        } catch let validation as SegmentResponseError {
            if Task.isCancelled { throw CancellationError() }
            sourceIndex += 1
            consecutiveValidationFailures += 1
            // Give every mirror one chance. If none can prove the requested range/identity, surface
            // the invariant failure to DownloadTask, which restarts coherently as a single stream.
            if consecutiveValidationFailures >= sources.count { throw validation }
            continue
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // A permanent HTTP response is permanent for this mirror, not necessarily for the
            // resource. Sweep the remaining mirrors without backoff before failing the download.
            // Local filesystem/configuration failures still stop immediately.
            if isPermanentHTTPFailure(error), sources.count > 1 {
                sourceIndex += 1
                consecutivePermanentSourceFailures += 1
                if consecutivePermanentSourceFailures >= sources.count { throw error }
                continue
            }
            if !isRetryableSegmentFailure(error) { throw error }
            lifetimeFailures += 1
            let retryScaled = settings.maxRetryAttempts > Int.max / 32
                ? Int.max : settings.maxRetryAttempts * 32
            let sourceScaled = sources.count > Int.max / 8 ? Int.max : sources.count * 8
            let lifetimeLimit = max(64, retryScaled, sourceScaled)
            guard lifetimeFailures <= lifetimeLimit else {
                throw DownloadError.retriesExhausted(lastReason: failureMessage(error))
            }
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

/// Open one body stream and prove its response describes the requested representation before any
/// bytes reach disk. Keeping request/response validation separate leaves `runSegment` as the retry
/// state machine and makes the successful transfer path independently readable.
private func openValidatedSegmentStream(
    url: URL,
    primaryURL: URL?,
    headers: [String: String],
    range: ClosedRange<Int64>?,
    username: String?,
    password: String?,
    expectedTotal: Int64?,
    expectedETag: String?,
    httpClient: any HTTPClient
) async throws -> AsyncThrowingStream<Data, Error> {
    var requestHeaders = headers
    let validator = sameOrigin(url, primaryURL) ? expectedETag : nil
    if range != nil, let validator, !validator.hasPrefix("W/"),
       !requestHeaders.keys.contains(where: { $0.caseInsensitiveCompare("If-Range") == .orderedSame }) {
        requestHeaders["If-Range"] = validator
    }
    let request = HTTPDownloadRequest(
        url: url,
        headers: requestHeaders,
        byteRange: range,
        username: username,
        password: password
    )
    let (head, stream) = try await httpClient.stream(request)
    // A Metalink mirror was never probed, so prove its range support and identity here rather than
    // assuming the download-level probe also described this source.
    try validateSegmentResponse(
        head: head,
        requestedRange: range,
        expectedTotal: expectedTotal,
        expectedETag: validator
    )
    return stream
}

/// Consume one already-validated response into its disjoint sparse-file range. Mutable cursor state
/// is passed back to the retry loop so a short stream resumes from the exact byte last committed.
private func transferSegmentBody(
    stream: AsyncThrowingStream<Data, Error>,
    local: inout DownloadSegment,
    currentEnd: inout Int64,
    requestedRange: ClosedRange<Int64>?,
    partPath: String,
    supportsRanges: Bool,
    totalKnown: Bool,
    limiters: [BandwidthLimiter],
    reserveBytes: @Sendable (Int) async -> SegmentWriteReservation,
    releaseBytes: @Sendable (Int) async -> Void,
    onBytes: @Sendable (Int) async -> Int64
) async throws {
    let handle = try SegmentFileHandle(partPath: partPath, startingAtOffset: local.currentOffset)
    defer { handle.close() }

    for try await chunk in stream {
        try Task.checkCancellation()
        if chunk.isEmpty { continue }

        // Trim to what this segment still needs; nil means its tail was stolen — stop writing.
        guard let data = capToSegment(
            chunk,
            totalKnown: totalKnown,
            supportsRanges: supportsRanges,
            offset: local.currentOffset,
            end: currentEnd
        ) else { break }

        // Claim the exact prefix before sleeping or writing. The actor serializes this with tail
        // stealing and caps the claim against the latest boundary, closing the former overlap window
        // between a worker's file write and its asynchronous progress report.
        let reservation = await reserveBytes(data.count)
        currentEnd = reservation.end
        guard reservation.byteCount > 0 else { break }
        let writable = reservation.byteCount == data.count
            ? data : Data(data.prefix(reservation.byteCount))
        do {
            for limiter in limiters where limiter.isLimited {
                await limiter.awaitAllowance(byteCount: writable.count)
            }
            // BandwidthLimiter intentionally has a non-throwing API. If its sleep was cancelled,
            // release the claim before the pending chunk reaches disk.
            try Task.checkCancellation()
            try handle.write(writable)
        } catch {
            await releaseBytes(reservation.byteCount)
            throw error
        }
        local.downloadedBytes += Int64(writable.count)
        currentEnd = await onBytes(writable.count)

        // Drain an original boundary through its terminal event. If work stealing shortened it after
        // this request began, stop early so the newly assigned tail exclusively owns those bytes.
        if totalKnown, supportsRanges, local.currentOffset > currentEnd,
           let requestedEnd = requestedRange?.upperBound, currentEnd < requestedEnd {
            break
        }
    }
    handle.synchronize()

    if !totalKnown { return }
    if local.currentOffset > currentEnd { return }
    // Stream ended before the segment completed — treat as a drop and resume.
    throw DownloadError.networkLost
}

private func isPermanentHTTPFailure(_ error: any Error) -> Bool {
    guard case .httpStatus(let code) = error as? DownloadError else { return false }
    return code != 408 && code != 425 && code != 429 && !(500...599).contains(code)
}

/// Prove a response can back *this* segment before any byte is written: status and returned interval
/// must match the request exactly, while known size and same-origin ETag must still describe the
/// probed representation. Any mismatch fails over or triggers a coherent whole-file restart.
private func validateSegmentResponse(
    head: HTTPResponseHead,
    requestedRange: ClosedRange<Int64>?,
    expectedTotal: Int64?,
    expectedETag: String?
) throws {
    if let requestedRange {
        guard head.statusCode == 206, head.contentRange == requestedRange else {
            throw SegmentResponseError.rangeNotHonored
        }
    }
    if let expectedTotal, let advertised = head.totalBytes, advertised != expectedTotal {
        throw SegmentResponseError.resourceChanged
    }
    if let expectedETag, let responseETag = head.etag,
       !expectedETag.isEmpty, !responseETag.isEmpty, expectedETag != responseETag {
        throw SegmentResponseError.resourceChanged
    }
}

private func sameOrigin(_ lhs: URL, _ rhs: URL?) -> Bool {
    guard let rhs else { return false }
    return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
        && lhs.host?.lowercased() == rhs.host?.lowercased()
        && lhs.port == rhs.port
}

/// Errors that can plausibly improve on another attempt/source. Permanent HTTP authorization/not-
/// found responses and local filesystem failures should surface immediately instead of burning the
/// exponential-backoff budget.
private func isRetryableSegmentFailure(_ error: any Error) -> Bool {
    guard let downloadError = error as? DownloadError else { return true }
    switch downloadError {
    case .httpStatus(let code):
        return code == 408 || code == 425 || code == 429 || (500...599).contains(code)
    case .networkLost, .retriesExhausted, .canceled:
        return true
    case .invalidURL, .fileSystem, .insufficientDiskSpace, .checksumMismatch, .underlying:
        return false
    }
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
