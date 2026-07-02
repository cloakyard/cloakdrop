import Foundation
import DownloadModels

/// An in-memory `HTTPClient` for tests and SwiftUI previews.
///
/// Serves byte ranges from fixed `Data`, can emulate servers that don't support `Range`
/// (forcing the single-stream fallback), and can inject a fixed number of mid-transfer
/// connection drops to exercise resume/retry — all without touching the network.
public final class MockHTTPClient: HTTPClient, @unchecked Sendable {
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

        public init(
            data: Data,
            acceptsRanges: Bool = true,
            suggestedFilename: String? = nil,
            etag: String? = nil,
            mimeType: String? = nil,
            finalURL: URL? = nil,
            advertisesSize: Bool = true
        ) {
            self.data = data
            self.acceptsRanges = acceptsRanges
            self.suggestedFilename = suggestedFilename
            self.etag = etag
            self.mimeType = mimeType
            self.finalURL = finalURL
            self.advertisesSize = advertisesSize
        }
    }

    private let lock = NSLock()
    private var resources: [URL: Resource]
    private var pendingDrops: Int
    private var dropAfterBytes: Int
    private var _probeCount = 0
    private var _streamCount = 0
    private var _lastRequest: HTTPDownloadRequest?

    /// Bytes per yielded chunk; small values stress chunk reassembly.
    public var chunkSize: Int = 16 * 1024
    /// Artificial delay between chunks, to make transfers slow enough to pause mid-flight in tests.
    public var perChunkDelay: Duration = .zero

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

    public func probe(_ request: HTTPDownloadRequest) async throws -> HTTPResponseHead {
        let resource: Resource? = lock.withLock {
            _probeCount += 1
            _lastRequest = request
            return resources[request.url]
        }
        guard let resource else { throw DownloadError.httpStatus(code: 404) }
        return HTTPResponseHead(
            statusCode: resource.acceptsRanges ? 206 : 200,
            totalBytes: resource.advertisesSize ? Int64(resource.data.count) : nil,
            acceptsRanges: resource.acceptsRanges,
            suggestedFilename: resource.suggestedFilename,
            etag: resource.etag,
            finalURL: resource.finalURL ?? request.url,
            mimeType: resource.mimeType
        )
    }

    public func stream(_ request: HTTPDownloadRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<Data, Error>) {
        struct StreamPlan { let resource: Resource; let willDrop: Bool; let dropAt: Int; let chunk: Int; let delay: Duration }
        let plan: StreamPlan? = lock.withLock {
            _streamCount += 1
            _lastRequest = request
            guard let resource = resources[request.url] else { return nil }
            let willDrop = pendingDrops > 0
            if willDrop { pendingDrops -= 1 }
            return StreamPlan(resource: resource, willDrop: willDrop, dropAt: dropAfterBytes, chunk: chunkSize, delay: perChunkDelay)
        }
        guard let plan else { throw DownloadError.httpStatus(code: 404) }
        let resource = plan.resource
        let willDrop = plan.willDrop
        let dropAt = plan.dropAt
        let chunk = plan.chunk
        let delay = plan.delay

        // Resolve the byte slice this request is for. `total` drives slicing; `reportedTotal` is what
        // the head advertises — `nil` when the resource emulates an unknown-size (chunked) response.
        let total = Int64(resource.data.count)
        let reportedTotal: Int64? = resource.advertisesSize ? total : nil
        let lower: Int64
        let upper: Int64
        if resource.acceptsRanges, let range = request.byteRange {
            lower = max(0, range.lowerBound)
            upper = min(total - 1, range.upperBound)
        } else {
            lower = 0
            upper = total - 1
        }
        guard lower <= upper else {
            // Empty range — return an immediately-finishing stream.
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            continuation.finish()
            let head = HTTPResponseHead(
                statusCode: 206,
                totalBytes: reportedTotal,
                acceptsRanges: resource.acceptsRanges,
                suggestedFilename: resource.suggestedFilename,
                etag: resource.etag,
                finalURL: resource.finalURL ?? request.url,
                mimeType: resource.mimeType
            )
            return (head, stream)
        }

        let slice = resource.data.subdata(in: Int(lower)..<Int(upper + 1))
        let head = HTTPResponseHead(
            statusCode: (resource.acceptsRanges && request.byteRange != nil) ? 206 : 200,
            totalBytes: total,
            acceptsRanges: resource.acceptsRanges,
            suggestedFilename: resource.suggestedFilename,
            etag: resource.etag,
            finalURL: resource.finalURL ?? request.url,
            mimeType: resource.mimeType
        )

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        Task {
            var delivered = 0
            var offset = 0
            while offset < slice.count {
                if willDrop && delivered >= dropAt {
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
            continuation.finish()
        }
        return (head, stream)
    }
}
