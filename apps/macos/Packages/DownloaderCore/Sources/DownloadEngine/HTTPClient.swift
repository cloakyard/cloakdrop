import Foundation
import DownloadModels

/// A single HTTP request the engine wants to make: a URL, optional extra headers, an optional
/// inclusive byte range, and optional HTTP authentication credentials.
public struct HTTPDownloadRequest: Sendable, Hashable {
    public var url: URL
    public var headers: [String: String]
    /// Inclusive byte range to request via the `Range` header, or `nil` for the whole resource.
    public var byteRange: ClosedRange<Int64>?
    /// HTTP authentication credentials (Basic preemptively; Basic/Digest/NTLM on challenge).
    public var username: String?
    public var password: String?

    public init(
        url: URL,
        headers: [String: String] = [:],
        byteRange: ClosedRange<Int64>? = nil,
        username: String? = nil,
        password: String? = nil
    ) {
        self.url = url
        self.headers = headers
        self.byteRange = byteRange
        self.username = username
        self.password = password
    }
}

extension HTTPDownloadRequest {
    static let sensitiveHeaderNames = ["Authorization", "Proxy-Authorization", "Cookie"]

    /// Mirrors are independent origins. A primary URL's flattened cookies and authentication must
    /// not accompany its body/probe to another server, port, or protocol.
    func forSource(_ source: URL) -> HTTPDownloadRequest {
        var result = self
        result.url = source
        guard !Self.sameOrigin(url, source) else { return result }
        result.username = nil
        result.password = nil
        result.headers = headers.filter { key, _ in
            !Self.sensitiveHeaderNames.contains { key.caseInsensitiveCompare($0) == .orderedSame }
        }
        return result
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int? {
            if let port = url.port { return port }
            switch url.scheme?.lowercased() {
            case "https": return 443
            case "http": return 80
            case "ftp": return 21
            case "ftps": return 990
            default: return nil
            }
        }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && port(lhs) == port(rhs)
    }
}

/// The metadata the engine needs from a server's response before/while transferring.
public struct HTTPResponseHead: Sendable, Hashable {
    public let statusCode: Int
    /// Total size of the *whole* resource in bytes, if determinable, else `nil`.
    public let totalBytes: Int64?
    /// Whether the server supports `Range` requests (and therefore resume & segmentation).
    public let acceptsRanges: Bool
    /// A server-suggested file name, if any (from `Content-Disposition` or the URL).
    public let suggestedFilename: String?
    /// The resource's `ETag`, used to detect mid-download changes.
    public let etag: String?
    /// The URL the request finally resolved to after any redirects. `nil` when the client
    /// doesn't track redirects (e.g. the in-memory mock, which never redirects).
    public let finalURL: URL?
    /// The resource's MIME type (`Content-Type` with parameters stripped, lowercased), if any.
    public let mimeType: String?
    /// The inclusive byte interval the server says this `206` body represents. `nil` for a full
    /// response, an unsatisfied range, or a malformed/missing `Content-Range` header. Segment
    /// workers validate this against the requested interval before writing any bytes.
    public let contentRange: ClosedRange<Int64>?

    public init(
        statusCode: Int,
        totalBytes: Int64?,
        acceptsRanges: Bool,
        suggestedFilename: String?,
        etag: String?,
        finalURL: URL? = nil,
        mimeType: String? = nil,
        contentRange: ClosedRange<Int64>? = nil
    ) {
        self.statusCode = statusCode
        self.totalBytes = totalBytes
        self.acceptsRanges = acceptsRanges
        self.suggestedFilename = suggestedFilename
        self.etag = etag
        self.finalURL = finalURL
        self.mimeType = mimeType
        self.contentRange = contentRange
    }

    /// Whether the status code is a 2xx success.
    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

/// Networking boundary for the engine. A protocol so the engine can run against an
/// in-memory fake in unit tests, and against `URLSession` in production.
public protocol HTTPClient: Sendable {
    /// Discover a resource's size and range-support without downloading its body.
    func probe(_ request: HTTPDownloadRequest) async throws -> HTTPResponseHead

    /// Begin transferring a (possibly ranged) request. Returns the response head and an
    /// async stream of body chunks. Cancelling the consuming task cancels the transfer.
    func stream(_ request: HTTPDownloadRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<Data, Error>)

    /// Apply network-level routing (proxy) for subsequent requests. Default: no-op.
    func configure(proxy: ProxyConfiguration) async
}

public extension HTTPClient {
    func configure(proxy: ProxyConfiguration) async {}
}
