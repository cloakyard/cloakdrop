import Foundation
import Testing
@testable import DownloadModels

@Suite("Captured download (intake payload)")
struct CapturedDownloadTests {

    // MARK: cloakdrop:// parsing

    @Test("Parses a full cloakdrop://add link into every field")
    func parsesFullLink() throws {
        let target = "https://example.com/big.zip"
        let referer = "https://example.com/page"
        let cookie = "session=abc; theme=dark"
        let ua = "Mozilla/5.0 (Macintosh)"
        // The target URL must be percent-encoded because it carries no query here, but referer/
        // cookie do contain reserved characters and must be encoded by the caller.
        var comps = URLComponents()
        comps.scheme = "cloakdrop"
        comps.host = "add"
        comps.queryItems = [
            .init(name: "url", value: target),
            .init(name: "filename", value: "big.zip"),
            .init(name: "referer", value: referer),
            .init(name: "cookie", value: cookie),
            .init(name: "ua", value: ua),
            .init(name: "header", value: "X-Token:secret123")
        ]
        let capture = try CapturedDownload.parse(cloakdropURL: comps.url!)

        #expect(capture.url.absoluteString == target)
        #expect(capture.suggestedFileName == "big.zip")
        #expect(capture.referrer == referer)
        #expect(capture.cookies == cookie)
        #expect(capture.userAgent == ua)
        #expect(capture.extraHeaders["X-Token"] == "secret123")
        #expect(capture.source == .urlScheme)
    }

    @Test("A bare url is enough; other fields stay nil")
    func parsesMinimalLink() throws {
        let capture = try CapturedDownload.parse(
            cloakdropURL: URL(string: "cloakdrop://add?url=https://example.com/file.bin")!
        )
        #expect(capture.url.absoluteString == "https://example.com/file.bin")
        #expect(capture.suggestedFileName == nil)
        #expect(capture.referrer == nil)
        #expect(capture.cookies == nil)
        #expect(capture.userAgent == nil)
        #expect(capture.extraHeaders.isEmpty)
    }

    @Test("A percent-encoded target url keeps its own query intact")
    func preservesEncodedTargetQuery() throws {
        // url=https://host/f?a=1&b=2 must be encoded so the outer parser doesn't split on '&'.
        let inner = "https://host.example/f?a=1&b=2"
        var comps = URLComponents()
        comps.scheme = "cloakdrop"
        comps.host = "add"
        comps.queryItems = [.init(name: "url", value: inner)]
        let capture = try CapturedDownload.parse(cloakdropURL: comps.url!)
        #expect(capture.url.absoluteString == inner)
        #expect(capture.url.query == "a=1&b=2")
    }

    @Test("cloakdropURL() round-trips back through the parser")
    func cloakdropURLRoundTrips() throws {
        let original = CapturedDownload(
            url: URL(string: "https://host.example/path/file.zip?a=1&b=2")!,
            suggestedFileName: "file.zip",
            referrer: "https://host.example/page",
            cookies: "session=abc; theme=dark",
            userAgent: "Mozilla/5.0 (Macintosh)",
            extraHeaders: ["X-Token": "secret123"],
            source: .shareExtension
        )
        let link = try #require(original.cloakdropURL())
        let parsed = try CapturedDownload.parse(cloakdropURL: link)
        #expect(parsed.url == original.url)
        #expect(parsed.suggestedFileName == original.suggestedFileName)
        #expect(parsed.referrer == original.referrer)
        #expect(parsed.cookies == original.cookies)
        #expect(parsed.userAgent == original.userAgent)
        #expect(parsed.extraHeaders == original.extraHeaders)
        // The parser always tags its result as urlScheme, regardless of the original source.
        #expect(parsed.source == .urlScheme)
    }

    @Test("Missing url query item is rejected")
    func rejectsMissingURL() {
        #expect(throws: CapturedDownload.CaptureError.missingURL) {
            _ = try CapturedDownload.parse(cloakdropURL: URL(string: "cloakdrop://add?filename=x")!)
        }
    }

    @Test("An action other than add is rejected")
    func rejectsUnknownAction() {
        #expect(throws: CapturedDownload.CaptureError.unsupportedAction("remove")) {
            _ = try CapturedDownload.parse(
                cloakdropURL: URL(string: "cloakdrop://remove?url=https://example.com/f")!
            )
        }
    }

    @Test("Non-http target schemes are rejected", arguments: [
        "file:///etc/passwd",
        "javascript:alert(1)",
        "data:text/plain;base64,QQ=="
    ])
    func rejectsInsecureSchemes(_ raw: String) {
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? raw
        #expect(throws: CapturedDownload.CaptureError.self) {
            _ = try CapturedDownload.parse(
                cloakdropURL: URL(string: "cloakdrop://add?url=\(encoded)")!
            )
        }
    }

    // MARK: filename sanitization

    @Test("Filenames are stripped of path separators so they can't escape the directory")
    func sanitizesFileName() throws {
        var comps = URLComponents()
        comps.scheme = "cloakdrop"
        comps.host = "add"
        comps.queryItems = [
            .init(name: "url", value: "https://example.com/x"),
            .init(name: "filename", value: "../../etc/evil:name.sh")
        ]
        let capture = try CapturedDownload.parse(cloakdropURL: comps.url!)
        let name = try #require(capture.suggestedFileName)
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(!name.contains("\\"))
    }

    // MARK: validation bounds

    @Test("An over-long cookie is rejected by validation")
    func rejectsOversizedField() {
        let capture = CapturedDownload(
            url: URL(string: "https://example.com/f")!,
            cookies: String(repeating: "a", count: CapturedDownload.Limits.cookies + 1),
            source: .safariExtension
        )
        #expect(throws: CapturedDownload.CaptureError.self) {
            _ = try capture.validated()
        }
    }

    @Test("Too many extra headers are rejected")
    func rejectsTooManyHeaders() {
        var headers: [String: String] = [:]
        for i in 0...CapturedDownload.Limits.headerCount { headers["H\(i)"] = "v" }
        let capture = CapturedDownload(
            url: URL(string: "https://example.com/f")!,
            extraHeaders: headers,
            source: .browserExtension
        )
        #expect(throws: CapturedDownload.CaptureError.tooManyHeaders(max: CapturedDownload.Limits.headerCount)) {
            _ = try capture.validated()
        }
    }

    @Test("A direct construction with an insecure scheme fails validation")
    func validatesScheme() {
        let capture = CapturedDownload(url: URL(string: "ftp://example.com/f")!, source: .services)
        #expect(throws: CapturedDownload.CaptureError.self) {
            _ = try capture.validated()
        }
    }

    // MARK: mapping to DownloadRequest

    @Test("toRequest folds user-agent and extra headers into request headers")
    func mapsToRequest() {
        let capture = CapturedDownload(
            url: URL(string: "https://example.com/f.zip")!,
            suggestedFileName: "f.zip",
            referrer: "https://example.com/",
            cookies: "a=b",
            userAgent: "UA/1.0",
            extraHeaders: ["X-Extra": "1"],
            source: .urlScheme
        )
        let request = capture.toRequest(destinationDirectoryPath: "/tmp/dl")

        #expect(request.url == capture.url)
        #expect(request.suggestedFileName == "f.zip")
        #expect(request.destinationDirectoryPath == "/tmp/dl")
        #expect(request.referrer == "https://example.com/")
        #expect(request.cookies == "a=b")
        #expect(request.requestHeaders["User-Agent"] == "UA/1.0")
        #expect(request.requestHeaders["X-Extra"] == "1")
    }

    // MARK: browser extension message

    @Test("Parses a full native-message dictionary from the browser extension")
    func parsesExtensionMessage() throws {
        let message: [String: Any] = [
            "url": "https://example.com/big.zip",
            "filename": "big.zip",
            "referrer": "https://example.com/page",
            "cookies": "session=abc; theme=dark",
            "userAgent": "Mozilla/5.0 (Macintosh)",
            "headers": ["X-Token": "secret123"]
        ]
        let capture = try CapturedDownload.parse(extensionMessage: message)

        #expect(capture.url.absoluteString == "https://example.com/big.zip")
        #expect(capture.suggestedFileName == "big.zip")
        #expect(capture.referrer == "https://example.com/page")
        #expect(capture.cookies == "session=abc; theme=dark")
        #expect(capture.userAgent == "Mozilla/5.0 (Macintosh)")
        #expect(capture.extraHeaders["X-Token"] == "secret123")
        #expect(capture.source == .safariExtension)
    }

    @Test("Blank string fields in a message are treated as absent")
    func extensionMessageBlanksAreNil() throws {
        let message: [String: Any] = [
            "url": "https://example.com/file.bin",
            "filename": "",
            "referrer": "   ",
            "cookies": "",
            "userAgent": ""
        ]
        let capture = try CapturedDownload.parse(extensionMessage: message)
        #expect(capture.suggestedFileName == nil)
        #expect(capture.referrer == nil)
        #expect(capture.cookies == nil)
        #expect(capture.userAgent == nil)
    }

    @Test("A message without a url is rejected")
    func extensionMessageMissingURL() {
        #expect(throws: CapturedDownload.CaptureError.missingURL) {
            _ = try CapturedDownload.parse(extensionMessage: ["filename": "x"])
        }
    }

    @Test("A message with an insecure target scheme is rejected")
    func extensionMessageInsecureScheme() {
        #expect(throws: CapturedDownload.CaptureError.self) {
            _ = try CapturedDownload.parse(extensionMessage: ["url": "file:///etc/passwd"])
        }
    }

    @Test("An oversized cookie from the extension is rejected by validation")
    func extensionMessageOversizedField() {
        let message: [String: Any] = [
            "url": "https://example.com/f",
            "cookies": String(repeating: "a", count: CapturedDownload.Limits.cookies + 1)
        ]
        #expect(throws: CapturedDownload.CaptureError.self) {
            _ = try CapturedDownload.parse(extensionMessage: message)
        }
    }

    // MARK: audio pairing (adaptive video + separate audio, e.g. YouTube)

    @Test("An audio param is parsed as the separate audio URL")
    func parsesAudioURL() throws {
        var comps = URLComponents()
        comps.scheme = "cloakdrop"
        comps.host = "add"
        comps.queryItems = [
            .init(name: "url", value: "https://cdn.example/video-only.mp4"),
            .init(name: "audio", value: "https://cdn.example/audio-only.m4a")
        ]
        let capture = try CapturedDownload.parse(cloakdropURL: comps.url!)
        #expect(capture.url.absoluteString == "https://cdn.example/video-only.mp4")
        #expect(capture.audioURL?.absoluteString == "https://cdn.example/audio-only.m4a")
    }

    @Test("audioURL round-trips through cloakdropURL()")
    func audioURLRoundTrips() throws {
        let original = CapturedDownload(
            url: URL(string: "https://cdn.example/v.mp4")!,
            audioURL: URL(string: "https://cdn.example/a.m4a")!,
            source: .browserExtension
        )
        let link = try #require(original.cloakdropURL())
        let parsed = try CapturedDownload.parse(cloakdropURL: link)
        #expect(parsed.audioURL == original.audioURL)
    }

    @Test("A native message's audioURL key is parsed")
    func parsesAudioURLFromExtensionMessage() throws {
        let capture = try CapturedDownload.parse(extensionMessage: [
            "url": "https://cdn.example/v.mp4",
            "audioURL": "https://cdn.example/a.m4a"
        ])
        #expect(capture.audioURL?.absoluteString == "https://cdn.example/a.m4a")
    }

    @Test("An insecure audio scheme is rejected by validation")
    func rejectsInsecureAudioScheme() {
        let capture = CapturedDownload(
            url: URL(string: "https://cdn.example/v.mp4")!,
            audioURL: URL(string: "file:///etc/passwd")!,
            source: .browserExtension
        )
        #expect(throws: CapturedDownload.CaptureError.self) {
            _ = try capture.validated()
        }
    }

    @Test("A capture serialized before audioURL existed still decodes (audioURL nil)")
    func decodesLegacyJSONWithoutAudioURL() throws {
        // JSON with no audioURL key — what an older build wrote to the App Group inbox.
        let json = #"{"url":"https://example.com/f.zip","extraHeaders":{},"source":"browserExtension"}"#
        let decoded = try JSONDecoder().decode(CapturedDownload.self, from: Data(json.utf8))
        #expect(decoded.url.absoluteString == "https://example.com/f.zip")
        #expect(decoded.audioURL == nil)
    }

    // MARK: Codable transport (App Group inbox)

    @Test("A capture survives a JSON encode/decode round-trip unchanged")
    func codableRoundTrip() throws {
        let capture = CapturedDownload(
            url: URL(string: "https://example.com/f.zip")!,
            suggestedFileName: "f.zip",
            referrer: "https://example.com/",
            cookies: "a=b; c=d",
            userAgent: "UA/2.0",
            extraHeaders: ["X-One": "1", "X-Two": "2"],
            source: .safariExtension
        )
        let data = try JSONEncoder().encode(capture)
        let decoded = try JSONDecoder().decode(CapturedDownload.self, from: data)
        #expect(decoded == capture)
    }
}
