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
    onBytes: @Sendable (Int) async -> Void
) async throws {
    var local = segment
    var attempt = 0

    while true {
        try Task.checkCancellation()
        if totalKnown && local.isComplete { return }

        let canResume = supportsRanges && totalKnown
        // A server without range support replays the whole body from byte 0 on every (re)connection,
        // so any bytes already written for this segment are stale. Rewind to the segment start and
        // correct the reported total before reopening the handle — otherwise a retry after a drop
        // (or a resume of a paused non-resumable download) writes byte-0 data at the advanced offset
        // and silently corrupts the file.
        if !canResume && local.downloadedBytes > 0 {
            await onBytes(-Int(local.downloadedBytes))
            local.downloadedBytes = 0
        }

        let range: ClosedRange<Int64>? = canResume ? (local.currentOffset...local.end) : nil
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
                    let remaining = local.remainingBytes
                    if Int64(data.count) > remaining {
                        data = data.prefix(Int(remaining))
                    }
                }
                for limiter in limiters {
                    await limiter.awaitAllowance(byteCount: data.count)
                }
                try handle.write(data)
                local.downloadedBytes += Int64(data.count)
                await onBytes(data.count)

                if totalKnown && supportsRanges && local.isComplete { break }
            }
            handle.synchronize()

            if !totalKnown { return }            // open-ended stream finished
            if local.isComplete { return }
            // Stream ended before the segment completed — treat as a drop and resume.
            throw DownloadError.networkLost
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            attempt += 1
            guard attempt <= settings.maxRetryAttempts else {
                throw DownloadError.retriesExhausted(lastReason: failureMessage(error))
            }
            let delay = BackoffPolicy.jittered(
                attempt: attempt,
                base: settings.retryBaseDelaySeconds,
                maximum: settings.retryMaxDelaySeconds
            )
            try await Task.sleep(for: .seconds(delay))
        }
    }
}

// MARK: - Media segment worker

/// Fetch one media segment fully (retrying with backoff on drops), decrypt it if AES-128, and write
/// it to its own file. Returns the bytes written. The whole segment is the resume unit: a failed
/// segment is re-fetched from scratch, and a completed segment leaves a file the next run skips.
/// Honors pause/cancel via task cancellation.
func runMediaSegment(
    segment: MediaSegment,
    filePath: String,
    key: Data?,
    headers: [String: String],
    httpClient: any HTTPClient,
    limiters: [BandwidthLimiter],
    settings: EngineSettings,
    onBytes: @Sendable (Int) async -> Void
) async throws -> Int {
    let byteRange = segment.byteRange.map { $0.offset...$0.end }
    var attempt = 0

    while true {
        try Task.checkCancellation()
        do {
            let request = HTTPDownloadRequest(url: segment.url, headers: headers, byteRange: byteRange)
            let (_, stream) = try await httpClient.stream(request)
            var buffer = Data()
            for try await chunk in stream {
                try Task.checkCancellation()
                if chunk.isEmpty { continue }
                for limiter in limiters { await limiter.awaitAllowance(byteCount: chunk.count) }
                buffer.append(chunk)
                await onBytes(chunk.count)
            }
            // A pause/cancel can end the stream early (a cancelled consumer's iterator just finishes),
            // so re-check before committing — otherwise we'd write a truncated segment and count it done.
            try Task.checkCancellation()

            var output = buffer
            if let key {
                let iv = AES128.iv(explicit: segment.encryption.iv, sequenceNumber: segment.id)
                output = try AES128.decryptCBC(buffer, key: key, iv: iv)
            }
            try output.write(to: URL(fileURLWithPath: filePath), options: .atomic)
            return output.count
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            attempt += 1
            guard attempt <= settings.maxRetryAttempts else {
                throw DownloadError.retriesExhausted(lastReason: failureMessage(error))
            }
            let delay = BackoffPolicy.jittered(
                attempt: attempt,
                base: settings.retryBaseDelaySeconds,
                maximum: settings.retryMaxDelaySeconds
            )
            try await Task.sleep(for: .seconds(delay))
        }
    }
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
