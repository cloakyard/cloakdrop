import Foundation
import DownloadModels

/// Errors specific to running a speed test.
public enum SpeedTestError: Error, Sendable, Hashable {
    /// The test server answered with a non-success HTTP status.
    case badStatus(Int)
    /// The server answered with something other than HTTP.
    case unsupportedResponse
    /// The provider's server directory returned no usable server.
    case noServers
}

/// Networking boundary for the speed tester — a protocol so the orchestration can run
/// against a scripted fake in unit tests and `URLSession` in production.
///
/// Streams carry *byte counts* (per received chunk / per sent body delta), not payloads:
/// the tester only ever measures, never stores.
public protocol SpeedTestTransport: Sendable {
    /// Small, timed GET — used for latency probes and the Ookla server directory.
    func fetch(_ url: URL) async throws -> Data

    /// GET `url` and stream the size of each received body chunk. Cancelling the consuming
    /// task cancels the transfer.
    func download(_ url: URL) async throws -> AsyncThrowingStream<Int, Error>

    /// POST `body` to `url` and stream sent-byte deltas as the upload progresses.
    /// Cancelling the consuming task cancels the transfer.
    func upload(_ url: URL, body: Data) async throws -> AsyncThrowingStream<Int, Error>
}

/// `SpeedTestTransport` backed by `URLSession`, using per-task delegates to observe body
/// chunks (download) and sent-byte deltas (upload) as they happen.
///
/// Byte counts are coalesced in the delegates (~150 ms / 1 MiB granularity) before they
/// cross into the `SpeedTester` actor — at gigabit rates per-chunk events would serialize
/// thousands of actor hops per second, and the bookkeeping would distort the measurement.
public final class URLSessionSpeedTestTransport: SpeedTestTransport {
    private let session: URLSession

    /// - Parameter proxy: routing for the test traffic. Defaults to the system proxy; pass
    ///   the user's configured proxy so the test measures the same path downloads take
    ///   (and never leaks the user's direct IP past a proxy they set up on purpose).
    public init(proxy: ProxyConfiguration = .system) {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        // One test saturates the link with several parallel streams to one host.
        config.httpMaximumConnectionsPerHost = 16
        self.session = URLSession(configuration: URLSessionHTTPClient.applyingProxy(proxy, to: config))
    }

    deinit {
        // Un-invalidated sessions are retained by the URL loading system for the app's
        // lifetime; without this every test run would leak a session + connection pool.
        session.invalidateAndCancel()
    }

    public func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(for: Self.makeRequest(url))
        try Self.validate(response)
        return data
    }

    public func download(_ url: URL) async throws -> AsyncThrowingStream<Int, Error> {
        let task = session.dataTask(with: Self.makeRequest(url))
        let (stream, continuation) = AsyncThrowingStream<Int, Error>.makeStream()
        task.delegate = DownloadChunkDelegate(continuation: continuation)
        continuation.onTermination = { reason in
            if case .cancelled = reason { task.cancel() }
        }
        task.resume()
        return stream
    }

    public func upload(_ url: URL, body: Data) async throws -> AsyncThrowingStream<Int, Error> {
        var request = Self.makeRequest(url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let task = session.uploadTask(with: request, from: body)
        let (stream, continuation) = AsyncThrowingStream<Int, Error>.makeStream()
        task.delegate = UploadProgressDelegate(continuation: continuation)
        continuation.onTermination = { reason in
            if case .cancelled = reason { task.cancel() }
        }
        task.resume()
        return stream
    }

    private static func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    fileprivate static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw SpeedTestError.unsupportedResponse }
        guard (200..<300).contains(http.statusCode) else { throw SpeedTestError.badStatus(http.statusCode) }
    }
}

/// Accumulates byte counts and decides when a coalesced total is worth yielding: at ~1 MiB
/// so fast links don't flood the consumer, or after ~150 ms so slow links still animate.
///
/// Not thread-safe by itself — URLSession serializes a task's delegate callbacks, which is
/// the only place this is mutated.
private struct ByteCoalescer {
    private var pending = 0
    private var lastFlush = ContinuousClock.now

    mutating func add(_ bytes: Int) -> Int? {
        pending += bytes
        guard pending >= 1 << 20 || lastFlush.duration(to: .now) > .milliseconds(150) else { return nil }
        return flush()
    }

    mutating func flush() -> Int? {
        defer { pending = 0; lastFlush = .now }
        return pending > 0 ? pending : nil
    }
}

/// Per-task delegate that turns a data task's body chunks into a stream of coalesced
/// chunk sizes.
private final class DownloadChunkDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<Int, Error>.Continuation
    private var coalescer = ByteCoalescer()

    init(continuation: AsyncThrowingStream<Int, Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        do {
            try URLSessionSpeedTestTransport.validate(response)
            return .allow
        } catch {
            continuation.finish(throwing: error)
            return .cancel
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let total = coalescer.add(data.count) {
            continuation.yield(total)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if error == nil, let remainder = coalescer.flush() {
            continuation.yield(remainder)
        }
        continuation.finish(throwing: error.map(Self.classify))
    }

    fileprivate static func classify(_ error: any Error) -> any Error {
        (error as NSError).code == NSURLErrorCancelled && (error as NSError).domain == NSURLErrorDomain
            ? CancellationError()
            : error
    }
}

/// Per-task delegate that turns an upload task's `didSendBodyData` callbacks into a stream
/// of coalesced sent-byte deltas, then validates the server's final status on completion.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<Int, Error>.Continuation
    private var coalescer = ByteCoalescer()

    init(continuation: AsyncThrowingStream<Int, Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        // Following a redirect makes URLSession re-send the whole body, and the delegate
        // would count those bytes twice — refuse, and let status validation fail the run
        // honestly instead of inflating the reported upload speed.
        nil
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        if let total = coalescer.add(Int(bytesSent)) {
            continuation.yield(total)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            continuation.finish(throwing: DownloadChunkDelegate.classify(error))
            return
        }
        do {
            guard let response = task.response else { throw SpeedTestError.unsupportedResponse }
            try URLSessionSpeedTestTransport.validate(response)
            if let remainder = coalescer.flush() {
                continuation.yield(remainder)
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}
