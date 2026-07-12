import Foundation
import DownloadModels

/// The production `HTTPClient` the engine uses: it routes each request by URL scheme — `ftp`/`ftps`
/// to the native `FTPClient`, everything else (`http`/`https`) to `URLSessionHTTPClient`. Because both
/// backends satisfy the same `HTTPClient` protocol, the rest of the engine (segmentation, resume,
/// throttle, persistence) is entirely unaware of which protocol a given download speaks.
public struct SchemeRoutingHTTPClient: HTTPClient {
    private let http: any HTTPClient
    private let ftp: any HTTPClient

    public init(http: any HTTPClient = URLSessionHTTPClient(), ftp: any HTTPClient = FTPClient()) {
        self.http = http
        self.ftp = ftp
    }

    private func client(for url: URL) -> any HTTPClient {
        switch url.scheme?.lowercased() {
        case "ftp", "ftps": return ftp
        default: return http
        }
    }

    public func probe(_ request: HTTPDownloadRequest) async throws -> HTTPResponseHead {
        try await client(for: request.url).probe(request)
    }

    public func stream(_ request: HTTPDownloadRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<Data, Error>) {
        try await client(for: request.url).stream(request)
    }

    public func configure(proxy: ProxyConfiguration) async {
        // Proxy applies to the HTTP backend; FTP transfers connect directly (passive mode).
        await http.configure(proxy: proxy)
    }
}
