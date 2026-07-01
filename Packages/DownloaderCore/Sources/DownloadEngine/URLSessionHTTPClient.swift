import Foundation
import CFNetwork
import DownloadModels

/// `HTTPClient` backed by `URLSession`.
///
/// Segment transfers use a delegate-driven session so body bytes arrive as `Data` chunks
/// (efficient, and cancellable mid-flight). Lightweight probes use a separate session and the
/// async convenience API. Both sessions answer authentication challenges from a shared,
/// lock-guarded per-host credential store, so HTTP Basic/Digest (and proxy) auth work on
/// probe and stream alike; TLS trust is left to the system's default handling.
///
/// The class is `@unchecked Sendable`: its mutable state (the task registry, the credential
/// store, and the swappable sessions) is each guarded by a lock.
public final class URLSessionHTTPClient: NSObject, HTTPClient, @unchecked Sendable {
    private let registry = TaskRegistry()
    private let credentials = CredentialBox()
    private let baseConfiguration: URLSessionConfiguration
    private let probeDelegate: AuthResponder

    private let sessionLock = NSLock()
    private var _streamSession: URLSession!
    private var _probeSession: URLSession
    private var currentProxy: ProxyConfiguration?

    public init(configuration: URLSessionConfiguration = URLSessionHTTPClient.defaultConfiguration()) {
        self.baseConfiguration = configuration
        self.probeDelegate = AuthResponder(credentials: credentials)
        self.currentProxy = nil
        self._probeSession = URLSession(configuration: configuration, delegate: probeDelegate, delegateQueue: nil)
        super.init()
        self._streamSession = Self.makeStreamSession(configuration: configuration, delegate: self)
    }

    public static func defaultConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldUsePipelining = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 16
        return config
    }

    private static func makeStreamSession(configuration: URLSessionConfiguration, delegate: URLSessionDataDelegate) -> URLSession {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.cloakyard.cloakdrop.urlsession.delegate"
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    }

    private var streamSession: URLSession {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _streamSession
    }
    private var probeSession: URLSession {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _probeSession
    }

    // MARK: HTTPClient

    public func probe(_ request: HTTPDownloadRequest) async throws -> HTTPResponseHead {
        registerCredentials(for: request)
        // A 0-0 ranged GET reveals both total size (via Content-Range) and range support
        // (206 vs 200) in one round trip, and works on servers that reject HEAD.
        var probe = request
        probe.byteRange = 0...0
        let urlRequest = Self.makeURLRequest(probe)
        // Stream, but never consume the body. A server that ignores `Range` answers a 0-0 GET
        // with `200` + the *entire* resource; `data(for:)` would buffer all of it into memory.
        // `bytes(for:)` hands back the head as soon as the response arrives — we read it and
        // cancel the task, so the body is never downloaded.
        let (bytes, response) = try await probeSession.bytes(for: urlRequest)
        bytes.task.cancel()
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.underlying(reason: "Server returned a non-HTTP response.")
        }
        let head = Self.parseHead(http)
        guard head.isSuccess || head.statusCode == 206 else {
            throw DownloadError.httpStatus(code: head.statusCode)
        }
        return head
    }

    public func stream(_ request: HTTPDownloadRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<Data, Error>) {
        registerCredentials(for: request)
        let urlRequest = Self.makeURLRequest(request)
        let task = streamSession.dataTask(with: urlRequest)
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let taskID = task.taskIdentifier

        let head: HTTPResponseHead = try await withCheckedThrowingContinuation { headContinuation in
            registry.register(
                taskID: taskID,
                handler: TaskHandler(data: continuation, head: headContinuation)
            )
            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason {
                    task.cancel()
                }
                self?.registry.remove(taskID: taskID)
            }
            task.resume()
        }
        return (head, stream)
    }

    public func configure(proxy: ProxyConfiguration) async {
        sessionLock.withLock {
            guard proxy != currentProxy else { return }
            currentProxy = proxy

            // Proxy credentials answer 407 challenges, keyed by the proxy host like server creds.
            if proxy.isUsableManualProxy && proxy.requiresCredentials {
                credentials.set(
                    URLCredential(user: proxy.username, password: proxy.password, persistence: .forSession),
                    for: proxy.host
                )
            }

            let config = Self.applyingProxy(proxy, to: baseConfiguration)
            _probeSession.invalidateAndCancel()
            _streamSession.invalidateAndCancel()
            _probeSession = URLSession(configuration: config, delegate: probeDelegate, delegateQueue: nil)
            _streamSession = Self.makeStreamSession(configuration: config, delegate: self)
        }
    }

    // MARK: Credentials

    private func registerCredentials(for request: HTTPDownloadRequest) {
        guard let user = request.username, !user.isEmpty,
              let password = request.password, let host = request.url.host else { return }
        credentials.set(URLCredential(user: user, password: password, persistence: .forSession), for: host)
    }

    fileprivate func resolveChallenge(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        Self.resolveChallenge(challenge, credentials: credentials)
    }

    static func resolveChallenge(
        _ challenge: URLAuthenticationChallenge,
        credentials: CredentialBox
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            return (.performDefaultHandling, nil)   // let the system validate TLS
        case NSURLAuthenticationMethodHTTPBasic,
             NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodNTLM:
            if challenge.previousFailureCount == 0,
               let credential = credentials.credential(for: challenge.protectionSpace.host) {
                return (.useCredential, credential)
            }
            return (.performDefaultHandling, nil)
        default:
            return (.performDefaultHandling, nil)
        }
    }

    // MARK: Request building

    private static func makeURLRequest(_ request: HTTPDownloadRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "GET"
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        // Preemptive Basic auth avoids a 401 round-trip; Digest/NTLM still answer on challenge.
        if let user = request.username, !user.isEmpty, let password = request.password {
            urlRequest.setValue(basicAuthorizationValue(user: user, password: password), forHTTPHeaderField: "Authorization")
        }
        if let range = request.byteRange {
            urlRequest.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        }
        return urlRequest
    }

    static func basicAuthorizationValue(user: String, password: String) -> String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    // MARK: Proxy configuration

    private static func applyingProxy(_ proxy: ProxyConfiguration, to base: URLSessionConfiguration) -> URLSessionConfiguration {
        guard let config = base.copy() as? URLSessionConfiguration else { return base }
        switch proxy.mode {
        case .system:
            config.connectionProxyDictionary = nil          // default: macOS system proxy
        case .direct:
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 0,
                kCFNetworkProxiesHTTPSEnable as String: 0,
                kCFNetworkProxiesSOCKSEnable as String: 0
            ]
        case .manual where proxy.isUsableManualProxy:
            config.connectionProxyDictionary = manualProxyDictionary(proxy)
        case .manual:
            config.connectionProxyDictionary = nil           // incomplete config → fall back to system
        }
        return config
    }

    private static func manualProxyDictionary(_ proxy: ProxyConfiguration) -> [String: Any] {
        switch proxy.type {
        case .http:
            return [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: proxy.host,
                kCFNetworkProxiesHTTPPort as String: proxy.port
            ]
        case .https:
            return [
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: proxy.host,
                kCFNetworkProxiesHTTPSPort as String: proxy.port
            ]
        case .socks5:
            return [
                kCFNetworkProxiesSOCKSEnable as String: 1,
                kCFNetworkProxiesSOCKSProxy as String: proxy.host,
                kCFNetworkProxiesSOCKSPort as String: proxy.port
            ]
        }
    }

    // MARK: Response parsing

    private static func parseHead(_ http: HTTPURLResponse) -> HTTPResponseHead {
        let status = http.statusCode
        var total: Int64?
        var acceptsRanges = false

        if status == 206, let contentRange = http.value(forHTTPHeaderField: "Content-Range") {
            // Format: "bytes 0-0/12345"
            acceptsRanges = true
            if let slash = contentRange.lastIndex(of: "/") {
                let totalString = contentRange[contentRange.index(after: slash)...]
                if totalString != "*" { total = Int64(totalString) }
            }
        } else {
            if let accept = http.value(forHTTPHeaderField: "Accept-Ranges") {
                acceptsRanges = accept.lowercased().contains("bytes")
            }
            let length = http.expectedContentLength
            total = length >= 0 ? length : nil
        }

        return HTTPResponseHead(
            statusCode: status,
            totalBytes: total,
            acceptsRanges: acceptsRanges,
            suggestedFilename: http.suggestedFilename,
            etag: http.value(forHTTPHeaderField: "ETag")
        )
    }
}

// MARK: - URLSession delegate

extension URLSessionHTTPClient: URLSessionDataDelegate {
    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else {
            registry.completeHead(
                taskID: dataTask.taskIdentifier,
                with: .failure(DownloadError.underlying(reason: "Non-HTTP response."))
            )
            return .cancel
        }
        let head = Self.parseHead(http)
        guard head.isSuccess || head.statusCode == 206 else {
            registry.completeHead(
                taskID: dataTask.taskIdentifier,
                with: .failure(DownloadError.httpStatus(code: head.statusCode))
            )
            return .cancel
        }
        registry.completeHead(taskID: dataTask.taskIdentifier, with: .success(head))
        return .allow
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        registry.yield(taskID: dataTask.taskIdentifier, data: data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        registry.finish(taskID: task.taskIdentifier, error: error)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        resolveChallenge(challenge)
    }
}

// MARK: - Probe-session auth delegate

/// A minimal delegate for the probe session: it answers authentication challenges from the
/// shared credential store but implements no data callbacks, so the async `data(for:)`
/// convenience keeps its normal behavior.
private final class AuthResponder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let credentials: CredentialBox
    init(credentials: CredentialBox) { self.credentials = credentials }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        URLSessionHTTPClient.resolveChallenge(challenge, credentials: credentials)
    }
}

// MARK: - Credential store

/// Lock-guarded per-host credential store shared by both sessions' challenge handlers.
final class CredentialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var byHost: [String: URLCredential] = [:]

    func set(_ credential: URLCredential, for host: String) {
        lock.lock(); defer { lock.unlock() }
        byHost[host] = credential
    }

    func credential(for host: String) -> URLCredential? {
        lock.lock(); defer { lock.unlock() }
        return byHost[host]
    }
}

// MARK: - Task registry

/// One in-flight task's continuations.
private struct TaskHandler {
    let data: AsyncThrowingStream<Data, Error>.Continuation
    var head: CheckedContinuation<HTTPResponseHead, Error>?
}

/// Lock-guarded map from `URLSessionTask.taskIdentifier` to its handler. Bridges the
/// delegate's serial queue to the async callers.
private final class TaskRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [Int: TaskHandler] = [:]

    func register(taskID: Int, handler: TaskHandler) {
        lock.lock(); defer { lock.unlock() }
        handlers[taskID] = handler
    }

    func remove(taskID: Int) {
        lock.lock(); defer { lock.unlock() }
        handlers[taskID] = nil
    }

    /// Resolve the head continuation exactly once.
    func completeHead(taskID: Int, with result: Result<HTTPResponseHead, Error>) {
        lock.lock()
        guard var handler = handlers[taskID], let head = handler.head else { lock.unlock(); return }
        handler.head = nil
        handlers[taskID] = handler
        lock.unlock()
        head.resume(with: result)
    }

    func yield(taskID: Int, data: Data) {
        lock.lock()
        let continuation = handlers[taskID]?.data
        lock.unlock()
        continuation?.yield(data)
    }

    func finish(taskID: Int, error: (any Error)?) {
        lock.lock()
        let handler = handlers[taskID]
        handlers[taskID] = nil
        lock.unlock()
        guard let handler else { return }
        // If the response never arrived, surface the failure to the awaiting head call too.
        if let head = handler.head {
            head.resume(throwing: error ?? DownloadError.canceled)
        }
        if let error {
            handler.data.finish(throwing: Self.classify(error))
        } else {
            handler.data.finish()
        }
    }

    private static func classify(_ error: any Error) -> any Error {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled:
                return DownloadError.canceled
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut:
                return DownloadError.networkLost
            default:
                break
            }
        }
        return error
    }
}
