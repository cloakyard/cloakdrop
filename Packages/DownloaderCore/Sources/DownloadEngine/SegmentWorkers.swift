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
    url: URL,
    headers: [String: String],
    username: String?,
    password: String?,
    partPath: String,
    supportsRanges: Bool,
    totalKnown: Bool,
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
        do {
            let request = HTTPDownloadRequest(url: url, headers: headers, byteRange: range, username: username, password: password)
            let (_, stream) = try await httpClient.stream(request)
            let handle = try SegmentFileHandle(partPath: partPath, startingAtOffset: local.currentOffset)
            defer { handle.close() }

            for try await chunk in stream {
                try Task.checkCancellation()
                if chunk.isEmpty { continue }

                var data = chunk
                if totalKnown && supportsRanges {
                    let remaining = currentEnd - local.currentOffset + 1
                    if remaining <= 0 { break }                  // our tail was stolen; nothing left to write
                    if Int64(data.count) > remaining {
                        data = data.prefix(Int(remaining))
                    }
                }
                for limiter in limiters {
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
            try await accountRetry(error: error, attempt: &attempt, progressMark: &progressMark,
                                   progress: local.currentOffset, settings: settings)
        }
    }
}

// MARK: - Media segment worker

/// Fetch one media segment (retrying with backoff on drops) and write it to its own file. Returns
/// the bytes written. A completed segment leaves a file the next run skips; pause/cancel is honored
/// via task cancellation.
///
/// A *cleartext* segment streams straight to a sibling `.partial` file — constant memory even when
/// the "segment" is a whole adaptive video (a paired video/audio grab is one file per stream) — and
/// a retry resumes from the bytes already on disk with a ranged request, so a drop late in a
/// gigabyte file doesn't start over. An AES-128 segment is buffered and decrypted whole; those are
/// small HLS chunks by construction, and CBC needs the complete ciphertext anyway.
///
/// `onExpectedBytes` reports the segment's expected size once known (explicit byte range, or the
/// response's total), so the caller can surface byte-accurate totals. `onBytes` reports transfer
/// deltas; a *negative* delta retracts bytes discarded by a restart (a resume the server refused).
func runMediaSegment(
    segment: MediaSegment,
    filePath: String,
    key: Data?,
    headers: [String: String],
    httpClient: any HTTPClient,
    limiters: [BandwidthLimiter],
    settings: EngineSettings,
    onExpectedBytes: @Sendable (Int64) async -> Void,
    onBytes: @Sendable (Int) async -> Void
) async throws -> Int {
    var fetch = MediaSegmentFetch(segment: segment, filePath: filePath)
    var attempt = 0
    var progressMark = partialSize(fetch.partialPath)

    while true {
        try Task.checkCancellation()
        do {
            if key != nil {
                return try await fetchEncryptedMediaSegment(
                    segment: segment, filePath: filePath, key: key, headers: headers,
                    httpClient: httpClient, limiters: limiters,
                    onExpectedBytes: onExpectedBytes, onBytes: onBytes
                )
            }
            return try await streamMediaSegmentToDisk(
                fetch: &fetch, headers: headers, httpClient: httpClient, limiters: limiters,
                onExpectedBytes: onExpectedBytes, onBytes: onBytes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // An expired/forbidden media link won't come back on retry — a googlevideo URL carries a
            // ~6 h `expire` and answers 403/410 once it lapses. Fail fast instead of spending the whole
            // retry budget (and the backoff delays) discovering the same permanent failure.
            if isPermanentHTTPFailure(error) { throw error }
            try await accountRetry(error: error, attempt: &attempt, progressMark: &progressMark,
                                   progress: partialSize(fetch.partialPath), settings: settings)
        }
    }
}

/// HTTP failures a retry won't fix: an expired signed URL (403), an unauthorized request (401), or a
/// resource that's gone (410). Retrying just burns the budget and the backoff delays.
private func isPermanentHTTPFailure(_ error: any Error) -> Bool {
    if case DownloadError.httpStatus(let code) = error { return code == 401 || code == 403 || code == 410 }
    return false
}

/// Per-segment fetch state carried across retries: where the segment starts in its resource, the
/// (inclusive) end once known — from an explicit byte range, a response's total, or a probe — and
/// whether the expected size was already reported.
private struct MediaSegmentFetch {
    let segment: MediaSegment
    let filePath: String
    var knownEnd: Int64?
    var expectedNotified = false

    init(segment: MediaSegment, filePath: String) {
        self.segment = segment
        self.filePath = filePath
        self.knownEnd = segment.byteRange?.end
    }

    var partialPath: String { filePath + ".partial" }
    var base: Int64 { segment.byteRange?.offset ?? 0 }

    /// The segment's expected byte count: an explicit range's length, else the response's total.
    func expectedLength(head: HTTPResponseHead) -> Int64? {
        segment.byteRange?.length ?? head.totalBytes
    }
}

/// One streaming attempt: resume from any `.partial` bytes with a ranged request (falling back to a
/// clean restart when the server won't honor it), append arriving chunks to disk, and promote the
/// partial to the final part file once the byte count checks out. Throws to signal "retry".
private func streamMediaSegmentToDisk(
    fetch: inout MediaSegmentFetch,
    headers: [String: String],
    httpClient: any HTTPClient,
    limiters: [BandwidthLimiter],
    onExpectedBytes: @Sendable (Int64) async -> Void,
    onBytes: @Sendable (Int) async -> Void
) async throws -> Int {
    let fm = FileManager.default
    var resumeFrom = partialSize(fetch.partialPath)

    // Resuming needs a bounded range. When a previous *run* left a partial (relaunch) we don't know
    // the end yet — learn it with a probe, or start clean if the server can't tell us / won't range.
    if resumeFrom > 0, fetch.knownEnd == nil {
        if let end = await probedInclusiveEnd(url: fetch.segment.url, headers: headers, httpClient: httpClient) {
            fetch.knownEnd = end
        } else {
            try? fm.removeItem(atPath: fetch.partialPath)
            resumeFrom = 0
        }
    }

    // A fresh whole-file grab (a paired video/audio stream: one file, no manifest byte range, no HLS
    // duration): probe for the size up front so the very first GET is *bounded* (bytes=0-(total-1)).
    // A bounded request sidesteps some CDNs' default-stream throttling — googlevideo's `n`-throttle in
    // particular crawls an open-ended GET — and makes completion verifiable. Segments carrying their
    // own byte range or an HLS duration keep the plain un-ranged first fetch.
    if resumeFrom == 0, fetch.knownEnd == nil, fetch.segment.byteRange == nil, fetch.segment.duration == 0 {
        fetch.knownEnd = await probedInclusiveEnd(url: fetch.segment.url, headers: headers, httpClient: httpClient)
    }

    let range = resolveMediaRange(fetch, resumeFrom: resumeFrom)
    let request = HTTPDownloadRequest(url: fetch.segment.url, headers: headers, byteRange: range)
    let (head, stream) = try await httpClient.stream(request)

    // We asked to resume but the server sent the whole body (no 206): retract the bytes we'd
    // already counted and restart from scratch — appending a full body would corrupt the segment.
    if resumeFrom > 0, head.statusCode != 206 {
        await onBytes(-Int(resumeFrom))
        try? fm.removeItem(atPath: fetch.partialPath)
        resumeFrom = 0
    }
    if fetch.knownEnd == nil, let total = head.totalBytes { fetch.knownEnd = total - 1 }
    if !fetch.expectedNotified, let expected = fetch.expectedLength(head: head) {
        fetch.expectedNotified = true
        await onExpectedBytes(expected)
    }

    if resumeFrom == 0 { fm.createFile(atPath: fetch.partialPath, contents: nil) }
    guard let handle = FileHandle(forWritingAtPath: fetch.partialPath) else {
        throw DownloadError.fileSystem(reason: "Could not open \(fetch.partialPath) for writing.")
    }
    var written = resumeFrom
    do {
        try handle.seekToEnd()
        for try await chunk in stream {
            try Task.checkCancellation()
            if chunk.isEmpty { continue }
            for limiter in limiters { await limiter.awaitAllowance(byteCount: chunk.count) }
            try handle.write(contentsOf: chunk)
            written += Int64(chunk.count)
            await onBytes(chunk.count)
        }
        try handle.close()
    } catch {
        try? handle.close()   // keep the partial — the next attempt resumes from it
        throw error
    }
    // A pause/cancel can end the stream early (a cancelled consumer's iterator just finishes), so
    // re-check before committing — the partial stays for the resume.
    try Task.checkCancellation()

    // If the length was never advertised (no Content-Length, and nothing above set it), a "clean" EOF
    // can be a silent throttle-close that truncated the file. A 0-0 ranged probe returns Content-Range
    // with the true total even when the GET omitted Content-Length — use it to verify before promoting.
    // When the size is genuinely undiscoverable, EOF is accepted (documented limit). Here `base` is 0
    // (a segment with a byte range would already have `knownEnd`), so the probed end is the segment's.
    if fetch.knownEnd == nil {
        fetch.knownEnd = await probedInclusiveEnd(url: fetch.segment.url, headers: headers, httpClient: httpClient)
    }
    // When the length is known, a short body is a silent drop — retry (and resume) instead of
    // promoting a truncated segment.
    if let end = fetch.knownEnd, written < end - fetch.base + 1 {
        throw DownloadError.networkLost
    }
    try? fm.removeItem(atPath: fetch.filePath)
    try fm.moveItem(atPath: fetch.partialPath, toPath: fetch.filePath)
    return Int(written)
}

/// One buffered attempt for an AES-128 segment: fetch fully, decrypt, write atomically.
private func fetchEncryptedMediaSegment(
    segment: MediaSegment,
    filePath: String,
    key: Data?,
    headers: [String: String],
    httpClient: any HTTPClient,
    limiters: [BandwidthLimiter],
    onExpectedBytes: @Sendable (Int64) async -> Void,
    onBytes: @Sendable (Int) async -> Void
) async throws -> Int {
    let byteRange = segment.byteRange.map { $0.offset...$0.end }
    let request = HTTPDownloadRequest(url: segment.url, headers: headers, byteRange: byteRange)
    let (head, stream) = try await httpClient.stream(request)
    if let expected = segment.byteRange?.length ?? head.totalBytes {
        await onExpectedBytes(expected)
    }
    var buffer = Data()
    for try await chunk in stream {
        try Task.checkCancellation()
        if chunk.isEmpty { continue }
        for limiter in limiters { await limiter.awaitAllowance(byteCount: chunk.count) }
        buffer.append(chunk)
        await onBytes(chunk.count)
    }
    try Task.checkCancellation()

    var output = buffer
    if let key {
        let iv = AES128.iv(explicit: segment.encryption.iv, sequenceNumber: segment.id)
        output = try AES128.decryptCBC(buffer, key: key, iv: iv)
    }
    try output.write(to: URL(fileURLWithPath: filePath), options: .atomic)
    return output.count
}

private func partialSize(_ path: String) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value) ?? 0
}

/// The byte range to request this attempt: resume from `resumeFrom` when a partial and a known end
/// exist; bound a fresh whole-file grab to its probed end; otherwise honor the segment's own byte
/// range (or nil for an open-ended fetch of an unknown-size stream).
private func resolveMediaRange(_ fetch: MediaSegmentFetch, resumeFrom: Int64) -> ClosedRange<Int64>? {
    if resumeFrom > 0, let end = fetch.knownEnd { return (fetch.base + resumeFrom)...end }
    if fetch.segment.byteRange == nil, let end = fetch.knownEnd { return fetch.base...end }
    return fetch.segment.byteRange.map { $0.offset...$0.end }
}

/// A 0-0 ranged probe's inclusive end (`total - 1`) when the server supports ranges, else nil. Range
/// support means a `Content-Range` header reveals the total even when the plain GET omitted
/// `Content-Length` — how we recover an unknown size to bound a request and verify completeness.
private func probedInclusiveEnd(url: URL, headers: [String: String], httpClient: any HTTPClient) async -> Int64? {
    guard let head = try? await httpClient.probe(HTTPDownloadRequest(url: url, headers: headers)),
          head.acceptsRanges, let total = head.totalBytes else { return nil }
    return total - 1
}

/// Shared retry accounting for both segment workers: count the attempt, but reset the budget whenever
/// the transfer advanced past `progressMark` — so `maxRetryAttempts` counts *consecutive stalled*
/// attempts, and a long, repeatedly-dropping transfer isn't killed while it's still making headway.
private func accountRetry(
    error: any Error, attempt: inout Int, progressMark: inout Int64, progress: Int64, settings: EngineSettings
) async throws {
    attempt += 1
    if progress > progressMark { attempt = 0; progressMark = progress }
    try await backoffOrThrow(attempt: attempt, settings: settings, lastError: error)
}

/// Sleep with jittered backoff before the next retry, or throw `retriesExhausted` once the attempt
/// budget is spent. Shared by the file and media segment workers.
private func backoffOrThrow(attempt: Int, settings: EngineSettings, lastError: any Error) async throws {
    guard attempt <= settings.maxRetryAttempts else {
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
