import Foundation
import Testing
@testable import DownloadEngine

@Suite("URLRequest building")
struct RequestBuilderTests {
    private let url = URL(string: "https://cdn.example.com/v.mp4")!

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
}
