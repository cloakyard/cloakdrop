import Foundation
import Testing
@testable import DownloadEngine

@Suite("URLRequest building")
struct RequestBuilderTests {
    private let url = URL(string: "https://cdn.example.com/v.mp4")!

    @Test("Authentication challenges cannot reuse credentials on another port, protocol, or proxy")
    func challengeCredentialsStayOnOrigin() {
        let credentials = CredentialBox()
        let credential = URLCredential(user: "origin", password: "private", persistence: .forSession)
        credentials.set(credential, for: url)
        func origin(_ scheme: String, _ port: Int) -> URLProtectionSpace {
            URLProtectionSpace(host: "cdn.example.com", port: port, protocol: scheme, realm: nil,
                               authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        }
        #expect(credentials.credential(for: origin("https", 443))?.user == "origin")
        #expect(credentials.credential(for: origin("https", 444)) == nil)
        #expect(credentials.credential(for: origin("http", 80)) == nil)
        let proxy = URLProtectionSpace(proxyHost: "cdn.example.com", port: 443,
                                       type: NSURLProtectionSpaceHTTPProxy, realm: nil,
                                       authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        #expect(credentials.credential(for: proxy) == nil)
        credentials.set(URLCredential(user: "proxy", password: "private", persistence: .forSession),
                        proxyHost: "cdn.example.com", port: 443)
        #expect(credentials.credential(for: proxy)?.user == "proxy")
        #expect(credentials.credential(for: origin("https", 443))?.user == "origin")
    }

    @Test("Mirror and redirect credentials are restricted to the original origin",
          arguments: ["https://other.example.com/file", "http://cdn.example.com/file", "https://cdn.example.com:444/file"])
    func credentialsDoNotCrossOrigins(destination: String) throws {
        let destination = try #require(URL(string: destination))
        let headers = ["aUthorizatioN": "Bearer secret", "cookie": "session=secret",
                       "Proxy-Authorization": "Basic secret", "Referer": "https://cdn.example.com/page"]
        let original = HTTPDownloadRequest(url: url, headers: headers, username: "user", password: "secret")
        let mirror = original.forSource(destination)
        #expect(mirror.username == nil)
        #expect(mirror.password == nil)
        #expect(mirror.headers == ["Referer": "https://cdn.example.com/page"])

        var redirected = URLSessionHTTPClient.makeURLRequest(original)
        redirected.url = destination
        let safe = URLSessionHTTPClient.redirectedRequest(redirected, from: url)
        #expect(safe.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(safe.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(safe.value(forHTTPHeaderField: "Proxy-Authorization") == nil)
        #expect(safe.value(forHTTPHeaderField: "Referer") == headers["Referer"])
    }

    @Test("Explicit default ports preserve authentication for the same origin")
    func sameOriginCredentialsPreserved() throws {
        let destination = try #require(URL(string: "https://cdn.example.com:443/other"))
        let request = HTTPDownloadRequest(url: url, headers: ["Cookie": "session=secret"],
                                          username: "user", password: "secret")
        let mirror = request.forSource(destination)
        #expect(mirror.headers == request.headers)
        #expect(mirror.username == request.username)
        #expect(mirror.password == request.password)
    }

    @Test("A default User-Agent is injected only when the caller didn't supply one")
    func defaultUserAgentInjectedWhenAbsent() {
        let bare = URLSessionHTTPClient.makeURLRequest(HTTPDownloadRequest(url: url))
        #expect(bare.value(forHTTPHeaderField: "User-Agent") == URLSessionHTTPClient.defaultUserAgent)
    }

    @Test("A captured browser User-Agent always wins (case-insensitive, no override)")
    func capturedUserAgentPreserved() {
        let lower = URLSessionHTTPClient.makeURLRequest(
            HTTPDownloadRequest(url: url, headers: ["user-agent": "CustomBrowser/9"])
        )
        #expect(lower.value(forHTTPHeaderField: "User-Agent") == "CustomBrowser/9")
    }

    @Test("A byte range still emits its Range header alongside the default UA")
    func rangeHeaderEmitted() {
        let req = URLSessionHTTPClient.makeURLRequest(HTTPDownloadRequest(url: url, byteRange: 100...199))
        #expect(req.value(forHTTPHeaderField: "Range") == "bytes=100-199")
        #expect(req.value(forHTTPHeaderField: "User-Agent") == URLSessionHTTPClient.defaultUserAgent)
    }

    @Test("Every transfer uses identity encoding so probe, ranges, and fallback address the same bytes")
    func transferRequestUsesIdentityEncoding() {
        let request = HTTPDownloadRequest(
            url: URL(string: "https://example.com/archive.zip")!,
            byteRange: 100...199
        )
        let built = URLSessionHTTPClient.makeURLRequest(request)
        #expect(built.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
        let whole = HTTPDownloadRequest(url: request.url)
        #expect(URLSessionHTTPClient.makeURLRequest(whole)
            .value(forHTTPHeaderField: "Accept-Encoding") == "identity")

        let callerOverride = HTTPDownloadRequest(
            url: request.url,
            headers: ["accept-encoding": "custom"],
            byteRange: request.byteRange
        )
        #expect(URLSessionHTTPClient.makeURLRequest(callerOverride)
            .value(forHTTPHeaderField: "Accept-Encoding") == "custom")
    }
}
