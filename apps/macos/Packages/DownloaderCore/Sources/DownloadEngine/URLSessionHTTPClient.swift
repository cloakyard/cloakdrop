import Foundation
import DownloadModels

/// `HTTPClient` backed by `URLSession`.
///
/// Segment transfers use a delegate-driven session so body bytes arrive as `Data` chunks
/// (efficient, and cancellable mid-flight). Lightweight probes use a separate session and the
/// async convenience API. Both sessions answer authentication challenges from a shared,
/// lock-guarded per-origin credential store, so HTTP Basic/Digest (and proxy) auth work on
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

    /// Cancel outstanding work and break URLSession's delegate-retention cycle. Long-lived engine
    /// clients do not need to call this; transient clients should invalidate when their request ends.
    public func invalidate() {
        sessionLock.withLock {
            _probeSession.invalidateAndCancel()
            _streamSession.invalidateAndCancel()
        }
    }

    public static func defaultConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldUsePipelining = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        // Match the user-visible hard ceiling. Automatic mode remains conservative (16 by default),
        // while an explicit 17...32 override must not be silently queued behind a lower URLSession cap.
        config.httpMaximumConnectionsPerHost = 32
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
        // An empty representation has no satisfiable byte range. Standards-compliant servers answer
        // our 0-0 probe with 416 + `Content-Range: bytes */0`; that is a successful zero-byte probe.
        if head.statusCode == 416, head.totalBytes == 0 { return head }
        guard head.isSuccess || head.statusCode == 206 else {
            throw DownloadError.httpStatus(code: head.statusCode)
        }
        // The request definitely carried Range: 0-0. Only an exact 206 response proves the server
        // honored it; `200 + Accept-Ranges: bytes` is merely an unfulfilled advertisement.
        let provedRanges = head.statusCode == 206 && head.contentRange == 0...0
        return HTTPResponseHead(
            statusCode: head.statusCode,
            totalBytes: head.totalBytes,
            acceptsRanges: provedRanges,
            suggestedFilename: head.suggestedFilename,
            etag: head.etag,
            finalURL: head.finalURL,
            mimeType: head.mimeType,
            contentRange: head.contentRange
        )
    }

    public func stream(_ request: HTTPDownloadRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<Data, Error>) {
        registerCredentials(for: request)
        let urlRequest = Self.makeURLRequest(request)
        let task = streamSession.dataTask(with: urlRequest)
        // Keep only a small number of network chunks ahead of the disk/rate-limited consumer. The
        // registry suspends the URLSession task if this fills and resumes it as space reappears.
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(8)
        )
        let taskID = ObjectIdentifier(task)

        let head: HTTPResponseHead = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { headContinuation in
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
                // Cancellation can race registration: a cancelled, not-yet-resumed URLSession task
                // can deliver its only completion before the handler exists. Check again after
                // registering so that race cannot strand the checked head continuation.
                if Task.isCancelled {
                    registry.finish(taskID: taskID, error: CancellationError())
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            // Cancellation can arrive before the body stream is returned, while the caller is still
            // awaiting response headers. Cancel the underlying request immediately instead of making
            // pause/cancel wait for the 60-second request timeout.
            self.registry.finish(taskID: taskID, error: CancellationError())
            task.cancel()
        }
        return (head, stream)
    }

    public func configure(proxy: ProxyConfiguration) async {
        sessionLock.withLock {
            guard proxy != currentProxy else { return }
            currentProxy = proxy

            // Proxy and origin credentials have separate scopes, even when hosts coincide.
            if proxy.isUsableManualProxy && proxy.requiresCredentials {
                credentials.set(
                    URLCredential(user: proxy.username, password: proxy.password, persistence: .forSession),
                    proxyHost: proxy.host, port: proxy.port
                )
            }

            let config = ProxyRouting.applying(proxy, to: baseConfiguration)
            _probeSession.invalidateAndCancel()
            _streamSession.invalidateAndCancel()
            _probeSession = URLSession(configuration: config, delegate: probeDelegate, delegateQueue: nil)
            _streamSession = Self.makeStreamSession(configuration: config, delegate: self)
        }
    }

    // MARK: Credentials

    private func registerCredentials(for request: HTTPDownloadRequest) {
        guard let user = request.username, !user.isEmpty,
              let password = request.password else { return }
        credentials.set(URLCredential(user: user, password: password, persistence: .forSession), for: request.url)
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
               let credential = credentials.credential(for: challenge.protectionSpace) {
                return (.useCredential, credential)
            }
            return (.performDefaultHandling, nil)
        default:
            return (.performDefaultHandling, nil)
        }
    }

    // MARK: Request building

    /// A stock desktop-Safari User-Agent, used only when the caller (a browser capture) didn't supply
    /// one. Many CDNs — googlevideo especially — throttle or reject a generic/non-browser UA.
    static let defaultUserAgent = DesktopUserAgent.safari()

    static func makeURLRequest(_ request: HTTPDownloadRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "GET"
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        // A captured browser User-Agent always wins; otherwise present a stock one so media hosts
        // don't see (and throttle) a bare URLSession agent.
        if !request.headers.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            urlRequest.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        }
        // Preemptive Basic auth avoids a 401 round-trip; Digest/NTLM still answer on challenge.
        if let user = request.username, !user.isEmpty, let password = request.password {
            urlRequest.setValue(basicAuthorizationValue(user: user, password: password), forHTTPHeaderField: "Authorization")
        }
        // Probe, ranged segments, and any whole-stream safety fallback must address the same identity
        // representation. Transparent gzip/brotli can otherwise change both length and byte offsets
        // between those requests. A caller-supplied encoding remains authoritative.
        if !request.headers.keys.contains(where: { $0.caseInsensitiveCompare("Accept-Encoding") == .orderedSame }) {
            urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }
        if let range = request.byteRange {
            urlRequest.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        }
        return urlRequest
    }

    static func basicAuthorizationValue(user: String, password: String) -> String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    static func redirectedRequest(_ request: URLRequest, from source: URL?) -> URLRequest {
        guard let source, let destination = request.url,
              !HTTPDownloadRequest.sameOrigin(source, destination) else { return request }
        var redirected = request
        for header in HTTPDownloadRequest.sensitiveHeaderNames {
            redirected.setValue(nil, forHTTPHeaderField: header)
        }
        return redirected
    }

    // MARK: Response parsing

    private static func parseHead(_ http: HTTPURLResponse) -> HTTPResponseHead {
        let status = http.statusCode
        var total: Int64?
        var acceptsRanges = false
        var returnedRange: ClosedRange<Int64>?

        if let value = http.value(forHTTPHeaderField: "Content-Range") {
            let parsed = parseContentRange(value)
            total = parsed.total
            returnedRange = parsed.range
            acceptsRanges = status == 206 && returnedRange != nil
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
            etag: http.value(forHTTPHeaderField: "ETag"),
            // `http.url` is the URL the request finally resolved to (URLSession follows redirects
            // by default); `http.mimeType` is the Content-Type with parameters already stripped.
            finalURL: http.url,
            mimeType: http.mimeType?.lowercased(),
            contentRange: returnedRange
        )
    }

    /// Parse both satisfied (`bytes 10-19/100`) and unsatisfied (`bytes */0`) Content-Range forms.
    private static func parseContentRange(_ value: String) -> (range: ClosedRange<Int64>?, total: Int64?) {
        let pieces = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1)
        guard pieces.count == 2, pieces[0].lowercased() == "bytes" else { return (nil, nil) }
        let rangeAndTotal = pieces[1].split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard rangeAndTotal.count == 2 else { return (nil, nil) }
        let total = rangeAndTotal[1] == "*" ? nil : Int64(rangeAndTotal[1])
        guard rangeAndTotal[0] != "*" else { return (nil, total) }
        let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let lower = Int64(bounds[0]), let upper = Int64(bounds[1]),
              lower >= 0, upper >= lower else { return (nil, total) }
        return (lower...upper, total)
    }
}

// MARK: - URLSession delegate

extension URLSessionHTTPClient: URLSessionDataDelegate {
    public func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        Self.redirectedRequest(request, from: response.url)
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else {
            registry.completeHead(
                taskID: ObjectIdentifier(dataTask),
                with: .failure(DownloadError.underlying(reason: "Non-HTTP response."))
            )
            return .cancel
        }
        let head = Self.parseHead(http)
        guard head.isSuccess || head.statusCode == 206 else {
            registry.completeHead(
                taskID: ObjectIdentifier(dataTask),
                with: .failure(DownloadError.httpStatus(code: head.statusCode))
            )
            return .cancel
        }
        registry.completeHead(taskID: ObjectIdentifier(dataTask), with: .success(head))
        return .allow
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if registry.yield(taskID: ObjectIdentifier(dataTask), data: data) {
            dataTask.suspend()
            registry.drainPending(taskID: ObjectIdentifier(dataTask), task: dataTask)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        registry.finish(taskID: ObjectIdentifier(task), error: error)
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
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        URLSessionHTTPClient.redirectedRequest(request, from: response.url)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        URLSessionHTTPClient.resolveChallenge(challenge, credentials: credentials)
    }
}

// MARK: - Credential store

/// Lock-guarded per-origin credential store shared by both sessions' challenge handlers. A host-only
/// key would send a HTTPS password to an HTTP downgrade or a different service on the same host.
final class CredentialBox: @unchecked Sendable {
    private struct Scope: Hashable {
        let host: String
        let port: Int
        let scheme: String
        let isProxy: Bool
    }
    private let lock = NSLock()
    private var byScope: [Scope: URLCredential] = [:]

    func set(_ credential: URLCredential, for url: URL) {
        guard let host = url.host else { return }
        let scheme = url.scheme?.lowercased() ?? ""
        let scope = Scope(host: host.lowercased(), port: url.port ?? Self.defaultPort(scheme), scheme: scheme, isProxy: false)
        lock.lock(); defer { lock.unlock() }
        byScope[scope] = credential
    }

    func set(_ credential: URLCredential, proxyHost: String, port: Int) {
        lock.lock(); defer { lock.unlock() }
        byScope[Scope(host: proxyHost.lowercased(), port: port, scheme: "", isProxy: true)] = credential
    }

    func credential(for protectionSpace: URLProtectionSpace) -> URLCredential? {
        let isProxy = protectionSpace.isProxy()
        let scheme = isProxy ? "" : protectionSpace.protocol?.lowercased() ?? ""
        let port = protectionSpace.port > 0 ? protectionSpace.port : Self.defaultPort(scheme)
        let scope = Scope(host: protectionSpace.host.lowercased(), port: port, scheme: scheme, isProxy: isProxy)
        lock.lock(); defer { lock.unlock() }
        return byScope[scope]
    }

    private static func defaultPort(_ scheme: String) -> Int {
        scheme == "https" ? 443 : 80
    }
}
