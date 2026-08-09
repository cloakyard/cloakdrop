import Foundation
import DownloadModels

/// An in-memory `HTTPClient` for tests and SwiftUI previews.
///
/// Serves byte ranges from fixed `Data`, can emulate servers that don't support `Range`
/// (forcing the single-stream fallback), and can inject a fixed number of mid-transfer
/// connection drops to exercise resume/retry — all without touching the network.
public final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    private struct StreamPlan {
        let resource: Resource
        let willDrop: Bool
        let dropAt: Int
        let chunk: Int
        let delay: Duration
        let slowFromOffset: Int64?
        let slowDelay: Duration
        let cleanCloseAt: Int
    }

    public struct Resource: Sendable {
        public var data: Data
        public var acceptsRanges: Bool
        public var suggestedFilename: String?
        public var etag: String?
        public var mimeType: String?
        /// A URL to report as the request's final destination, emulating a redirect. `nil` means
        /// "no redirect" — the head reports the requested URL as final.
        public var finalURL: URL?
        /// Whether the server advertises the resource size (`Content-Length`). `false` emulates a
        /// chunked/streamed response with an unknown total.
        public var advertisesSize: Bool
        /// Override whether body requests honor Range after a successful range probe. This models
        /// origins/proxies that advertise or initially prove ranges but later reply with a full 200.
        public var streamHonorsRanges: Bool?
        /// Shift the returned 206 interval while retaining its length, modeling a malformed cache or
        /// origin that serves the wrong Content-Range. Zero is the normal, correct behavior.
        public var responseRangeOffsetDelta: Int64

        public init(
            data: Data,
            acceptsRanges: Bool = true,
            suggestedFilename: String? = nil,
            etag: String? = nil,
            mimeType: String? = nil,
            finalURL: URL? = nil,
            advertisesSize: Bool = true,
            streamHonorsRanges: Bool? = nil,
            responseRangeOffsetDelta: Int64 = 0
        ) {
            self.data = data
            self.acceptsRanges = acceptsRanges
            self.suggestedFilename = suggestedFilename
            self.etag = etag
            self.mimeType = mimeType
            self.finalURL = finalURL
            self.advertisesSize = advertisesSize
            self.streamHonorsRanges = streamHonorsRanges
            self.responseRangeOffsetDelta = responseRangeOffsetDelta
        }
    }

    private let lock = NSLock()
    private var resources: [URL: Resource]
    private var pendingDrops: Int
    private var dropAfterBytes: Int
    private var _probeCount = 0
    private var _streamCount = 0
    private var _lastRequest: HTTPDownloadRequest?
    private var _streamedURLs: [URL] = []
    private var _streamedRequests: [HTTPDownloadRequest] = []
    private var _activeStreamCount = 0
    private var _peakActiveStreamCount = 0

    /// Bytes per yielded chunk; small values stress chunk reassembly.
    public var chunkSize: Int = 16 * 1024
    /// Artificial delay between chunks, to make transfers slow enough to pause mid-flight in tests.
    public var perChunkDelay: Duration = .zero
    /// Requests whose range starts at or beyond this offset deliver at `slowChunkDelay` per chunk
    /// instead of `perChunkDelay`, making that tail a deterministic straggler — used to exercise
    /// dynamic segment re-splitting (work-stealing).
    public var slowFromOffset: Int64?
    public var slowChunkDelay: Duration = .zero
    /// The first `stream` finishes *cleanly* (no error) after this many delivered bytes, emulating a
    /// silent throttle-close that ends the body early — with no `Content-Length` to reveal it was
    /// short. `0` disables. Pair with `advertisesSize: false` to exercise truncation detection.
    public var cleanCloseAfterBytes: Int = 0
    private var _cleanCloseUsed = false

    public init(resources: [URL: Resource] = [:], pendingDrops: Int = 0, dropAfterBytes: Int = 0) {
        self.resources = resources
        self.pendingDrops = pendingDrops
        self.dropAfterBytes = dropAfterBytes
    }

    public func setResource(_ resource: Resource, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        resources[url] = resource
    }

    public var probeCount: Int { lock.withLock { _probeCount } }
    public var streamCount: Int { lock.withLock { _streamCount } }
    /// The most recent request seen by `probe`/`stream`, for asserting threaded values (auth, headers).
    public var lastRequest: HTTPDownloadRequest? { lock.withLock { _lastRequest } }
    /// Every URL `stream` was called with, in order — lets a test assert which mirrors were used
    /// (multi-source spread) and that a dead mirror was retried against a live one (failover).
    public var streamedURLs: [URL] { lock.withLock { _streamedURLs } }
    /// Every body request, for validating Range/If-Range/header behavior in integration tests.
    public var streamedRequests: [HTTPDownloadRequest] { lock.withLock { _streamedRequests } }
    public var peakActiveStreamCount: Int { lock.withLock { _peakActiveStreamCount } }

    private func streamFinished() {
        lock.withLock { _activeStreamCount = max(0, _activeStreamCount - 1) }
    }

    private func makeStreamPlan(for request: HTTPDownloadRequest) -> StreamPlan? {
        lock.withLock {
            _streamCount += 1
            _lastRequest = request
            _streamedURLs.append(request.url)
            _streamedRequests.append(request)
            guard let resource = resources[request.url] else { return nil }
            _activeStreamCount += 1
            _peakActiveStreamCount = max(_peakActiveStreamCount, _activeStreamCount)
            let willDrop = pendingDrops > 0
            if willDrop { pendingDrops -= 1 }
            let cleanCloseAt = (cleanCloseAfterBytes > 0 && !_cleanCloseUsed) ? cleanCloseAfterBytes : 0
            if cleanCloseAt > 0 { _cleanCloseUsed = true }
            return StreamPlan(
                resource: resource,
                willDrop: willDrop,
                dropAt: dropAfterBytes,
                chunk: chunkSize,
                delay: perChunkDelay,
                slowFromOffset: slowFromOffset,
                slowDelay: slowChunkDelay,
                cleanCloseAt: cleanCloseAt
            )
        }
    }

    public func probe(_ request: HTTPDownloadRequest) async throws -> HTTPResponseHead {
        let resource: Resource? = lock.withLock {
            _probeCount += 1
            _lastRequest = request
            return resources[request.url]
        }
        guard let resource else { throw DownloadError.httpStatus(code: 404) }
        let isEmpty = resource.data.isEmpty
        return HTTPResponseHead(
            statusCode: isEmpty && resource.acceptsRanges ? 416 : (resource.acceptsRanges ? 206 : 200),
            // A 0-0 ranged probe returns Content-Range (hence the total) whenever the server supports
            // ranges — even if the plain GET omits Content-Length. A non-range server only reveals the
            // total via Content-Length (advertisesSize).
            totalBytes: (resource.acceptsRanges || resource.advertisesSize) ? Int64(resource.data.count) : nil,
            acceptsRanges: resource.acceptsRanges && !isEmpty,
            suggestedFilename: resource.suggestedFilename,
            etag: resource.etag,
            finalURL: resource.finalURL ?? request.url,
            mimeType: resource.mimeType,
            contentRange: resource.acceptsRanges && !isEmpty ? 0...0 : nil
        )
    }

    private func makeHead(
        _ resource: Resource,
        statusCode: Int,
        totalBytes: Int64?,
        request: HTTPDownloadRequest,
        contentRange: ClosedRange<Int64>? = nil
    ) -> HTTPResponseHead {
        HTTPResponseHead(
            statusCode: statusCode, totalBytes: totalBytes, acceptsRanges: resource.acceptsRanges,
            suggestedFilename: resource.suggestedFilename, etag: resource.etag,
            finalURL: resource.finalURL ?? request.url, mimeType: resource.mimeType,
            contentRange: contentRange
        )
    }

    public func stream(_ request: HTTPDownloadRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<Data, Error>) {
        let plan = makeStreamPlan(for: request)
        guard let plan else { throw DownloadError.httpStatus(code: 404) }
        let resource = plan.resource
        let willDrop = plan.willDrop
        let dropAt = plan.dropAt
        let chunk = plan.chunk

        // Resolve the byte slice this request is for. `total` drives slicing; `reportedTotal` is what
        // the head advertises — `nil` when the resource emulates an unknown-size (chunked) response.
        let total = Int64(resource.data.count)
        let reportedTotal: Int64? = resource.advertisesSize ? total : nil
        let lower: Int64
        let upper: Int64
        let honorsRanges = resource.streamHonorsRanges ?? resource.acceptsRanges
        if honorsRanges, let range = request.byteRange {
            let requestedLength = range.upperBound - range.lowerBound + 1
            lower = max(0, min(total, range.lowerBound + resource.responseRangeOffsetDelta))
            upper = min(total - 1, lower + requestedLength - 1)
        } else {
            lower = 0
            upper = total - 1
        }
        guard lower <= upper else {
            // Empty range — return an immediately-finishing stream.
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            continuation.finish()
            streamFinished()
            return (makeHead(resource, statusCode: 206, totalBytes: reportedTotal, request: request), stream)
        }

        // A tail past `slowFromOffset` streams at the slow rate, making it a deterministic straggler.
        let delay: Duration = (plan.slowFromOffset.map { lower >= $0 } ?? false) ? plan.slowDelay : plan.delay

        let slice = resource.data.subdata(in: Int(lower)..<Int(upper + 1))
        // Respect `advertisesSize`: a chunked/streamed response omits Content-Length, so the head
        // reports no total (reportedTotal) even though the mock knows the full size internally.
        let head = makeHead(
            resource, statusCode: (honorsRanges && request.byteRange != nil) ? 206 : 200,
            totalBytes: reportedTotal, request: request,
            contentRange: honorsRanges && request.byteRange != nil ? lower...upper : nil
        )

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        Task { [weak self] in
            var delivered = 0
            var offset = 0
            while offset < slice.count {
                if plan.cleanCloseAt > 0 && delivered >= plan.cleanCloseAt {
                    self?.streamFinished()
                    continuation.finish()          // clean EOF (no error) — a silent throttle-close
                    return
                }
                if willDrop && delivered >= dropAt {
                    self?.streamFinished()
                    continuation.finish(throwing: DownloadError.networkLost)
                    return
                }
                let end = min(offset + chunk, slice.count)
                let piece = slice.subdata(in: offset..<end)
                continuation.yield(piece)
                delivered += piece.count
                offset = end
                if delay > .zero {
                    try? await Task.sleep(for: delay)
                } else {
                    await Task.yield()
                }
            }
            self?.streamFinished()
            continuation.finish()
        }
        return (head, stream)
    }
}
