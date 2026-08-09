import Foundation
import DownloadModels

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
    /// True once a probe has *confirmed the server honors ranges* — the gate for chunked downloading.
    /// A size learned from a plain `Content-Length` (a range-ignoring 200) doesn't set this, so such a
    /// server keeps the single-request path (which restarts cleanly) instead of a doomed chunk loop.
    var rangeCapable = false

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

/// Probe a segment's size and range support (both needed to bound and chunk a whole-file grab),
/// setting `knownEnd`/`rangeCapable`. Returns the resume offset, reset to 0 when a relaunch partial
/// can't be ranged against so the grab restarts clean.
private func prepareMediaSize(
    _ fetch: inout MediaSegmentFetch, resumeFrom: Int64,
    headers: [String: String], httpClient: any HTTPClient
) async -> Int64 {
    var resumeFrom = resumeFrom
    // A relaunch partial has an unknown end — learn it with a probe, or start clean if the server
    // can't tell us / won't range.
    if resumeFrom > 0, fetch.knownEnd == nil {
        if let end = await probedInclusiveEnd(url: fetch.segment.url, headers: headers, httpClient: httpClient) {
            fetch.knownEnd = end
            fetch.rangeCapable = true
        } else {
            try? FileManager.default.removeItem(atPath: fetch.partialPath)
            resumeFrom = 0
        }
    }
    // A fresh whole-file grab (a paired video/audio stream: one file, no manifest byte range, no HLS
    // duration): probe the size up front so it can be fetched in bounded chunks and its completion
    // verified.
    if resumeFrom == 0, fetch.knownEnd == nil, fetch.segment.byteRange == nil, fetch.segment.duration == 0 {
        if let end = await probedInclusiveEnd(url: fetch.segment.url, headers: headers, httpClient: httpClient) {
            fetch.knownEnd = end
            fetch.rangeCapable = true
        }
    }
    // A partial bigger than the resource itself (a stale leftover) can't be a valid prefix — discard it
    // and start clean rather than promote it unread. Its bytes aren't counted yet (a relaunch counts
    // only complete parts), so there's nothing to retract.
    if let end = fetch.knownEnd, resumeFrom > end - fetch.base + 1 {
        try? FileManager.default.removeItem(atPath: fetch.partialPath)
        resumeFrom = 0
    }
    return resumeFrom
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
    var resumeFrom = await prepareMediaSize(&fetch, resumeFrom: partialSize(fetch.partialPath),
                                            headers: headers, httpClient: httpClient)

    // Whole-file grab on a range-capable server: fetch it in bounded ~10 MB chunks (see
    // `streamMediaChunked`). Byte-range (DASH) or undiscoverable-size segments take the path below.
    if fetch.rangeCapable, fetch.segment.byteRange == nil, let knownEnd = fetch.knownEnd {
        if !fetch.expectedNotified {
            fetch.expectedNotified = true
            await onExpectedBytes(knownEnd - fetch.base + 1)
        }
        return try await streamMediaChunked(
            fetch: fetch, knownEnd: knownEnd, resumeFrom: resumeFrom, headers: headers,
            httpClient: httpClient, limiters: limiters, onBytes: onBytes
        )
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
            for limiter in limiters where limiter.isLimited { await limiter.awaitAllowance(byteCount: chunk.count) }
            try Task.checkCancellation()
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

/// yt-dlp's proven chunk size: a single large GET of a throttled CDN URL crawls; ~10 MB ranges fly.
private let mediaChunkSize: Int64 = 10 * 1024 * 1024

/// Download a whole-file media segment (known size, range-capable server) as a sequence of bounded
/// ~10 MB ranged requests appended to `.partial` — sidestepping the per-connection throttling a single
/// large GET triggers on YouTube-like CDNs. A dropped chunk throws so `runMediaSegment` resumes.
private func streamMediaChunked(
    fetch: MediaSegmentFetch,
    knownEnd: Int64,
    resumeFrom: Int64,
    headers: [String: String],
    httpClient: any HTTPClient,
    limiters: [BandwidthLimiter],
    onBytes: @Sendable (Int) async -> Void
) async throws -> Int {
    let fm = FileManager.default
    let base = fetch.base
    let total = knownEnd - base + 1

    if resumeFrom == 0 { fm.createFile(atPath: fetch.partialPath, contents: nil) }
    guard let handle = FileHandle(forWritingAtPath: fetch.partialPath) else {
        throw DownloadError.fileSystem(reason: "Could not open \(fetch.partialPath) for writing.")
    }
    var written = resumeFrom
    do {
        try handle.seekToEnd()
        while written < total {
            try Task.checkCancellation()
            let start = base + written
            let end = min(start + mediaChunkSize - 1, knownEnd)
            let request = HTTPDownloadRequest(url: fetch.segment.url, headers: headers, byteRange: start...end)
            let (head, stream) = try await httpClient.stream(request)
            // A range-capable server answers 206; a 200 (whole body) is only safe on a from-scratch
            // first chunk — appending it after a resume would corrupt the file, so retry instead.
            guard head.statusCode == 206 || (written == 0 && head.statusCode == 200) else {
                throw DownloadError.networkLost
            }
            // Guard against a stale cache / an object that changed under a stable URL: a response whose
            // reported total no longer matches the size we bounded to would splice mismatched bytes at
            // our offset and promote a corrupt file (a media grab has no whole-file checksum to catch it).
            if let served = head.totalBytes, served != total {
                throw DownloadError.networkLost
            }
            var chunkBytes = 0
            for try await data in stream {
                try Task.checkCancellation()
                if data.isEmpty { continue }
                for limiter in limiters where limiter.isLimited { await limiter.awaitAllowance(byteCount: data.count) }
                try Task.checkCancellation()
                try handle.write(contentsOf: data)
                chunkBytes += data.count
                written += Int64(data.count)
                await onBytes(data.count)
            }
            // A throttle-close can end a chunk with nothing delivered; bail so the retry backs off
            // rather than spinning a zero-progress loop.
            if chunkBytes == 0 { throw DownloadError.networkLost }
        }
        try handle.close()
    } catch {
        try? handle.close()   // keep the partial — the next attempt resumes from it
        throw error
    }
    try Task.checkCancellation()
    if written < total { throw DownloadError.networkLost }   // short overall body → retry & resume
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
        try Task.checkCancellation()
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
