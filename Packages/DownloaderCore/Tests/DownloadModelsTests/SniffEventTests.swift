import Foundation
import Testing
@testable import DownloadModels

@Suite("Sniff envelope (collector wire format)")
struct SniffEnvelopeTests {
    @Test func decodesAMixedBatch() throws {
        let json = """
        {"v":1,"frame":"https://site.example.com/watch","top":true,"events":[
          {"kind":"resource","url":"https://cdn.example.com/master.m3u8","initiator":"fetch","size":1200},
          {"kind":"response","url":"https://x.com/live?id=9","contentType":"application/vnd.apple.mpegurl"},
          {"kind":"element","url":"https://cdn.example.com/movie.mp4","tag":"video","duration":12.5},
          {"kind":"mse","url":"mse:video/mp4","mime":"video/mp4; codecs=\\"avc1\\""},
          {"kind":"drm","url":"drm:com.apple.fps","keySystem":"com.apple.fps"},
          {"kind":"page","url":"https://site.example.com/watch","title":"A Video","players":[{"video":true,"area":409920}],"blob":true},
          {"kind":"navigated","url":"https://site.example.com/next"}
        ]}
        """
        let envelope = try JSONDecoder().decode(SniffEnvelope.self, from: Data(json.utf8))
        #expect(envelope.version == 1)
        #expect(envelope.frameURL == "https://site.example.com/watch")
        #expect(envelope.isTopFrame)
        #expect(envelope.events.count == 7)
        #expect(envelope.events[0].kind == .resource)
        #expect(envelope.events[0].size == 1200)
        #expect(envelope.events[3].mime == "video/mp4; codecs=\"avc1\"")
        #expect(envelope.events[5].players == [MediaSniffer.SniffedPlayer(video: true, area: 409_920)])
        #expect(envelope.events[5].blob == true)
    }

    @Test func malformedOrUnknownEventsAreDroppedNotFatal() throws {
        let json = """
        {"v":1,"frame":"f","top":false,"events":[
          {"kind":"resource","url":"https://a.com/x.mp4"},
          {"kind":"somethingNew","url":"https://a.com/y"},
          "not-even-an-object",
          {"kind":"resource","url":"https://a.com/z.zip"}
        ]}
        """
        let envelope = try JSONDecoder().decode(SniffEnvelope.self, from: Data(json.utf8))
        #expect(envelope.events.count == 2)
        #expect(envelope.events.map(\.url) == ["https://a.com/x.mp4", "https://a.com/z.zip"])
    }

    @Test func parsesAScriptMessageBodyAndRejectsJunk() {
        let body: [String: Any] = [
            "v": 1, "frame": "https://f.example.com", "top": true,
            "events": [["kind": "resource", "url": "https://a.com/x.mp4", "size": 9000]]
        ]
        let envelope = SniffEnvelope.parse(messageBody: body)
        #expect(envelope?.events.first?.url == "https://a.com/x.mp4")
        #expect(SniffEnvelope.parse(messageBody: "just a string") == nil)
        #expect(SniffEnvelope.parse(messageBody: Date()) == nil)   // not JSON-serializable
    }

    /// The JS half of the wire format must name every event kind the Swift half decodes — a drifted
    /// collector would silently stop feeding a channel.
    @Test func collectorScriptCoversEveryEventKind() {
        let script = MediaSniffer.collectorScript
        #expect(!script.isEmpty, "MediaSniffer.js must ship in the DownloadModels resource bundle")
        for kind in ["resource", "response", "element", "mse", "drm", "page", "navigated"] {
            #expect(script.contains("\"\(kind)\""), "collector never emits kind \(kind)")
        }
        #expect(script.contains("mediaSniffer"), "collector must post to the mediaSniffer handler")
        #expect(script.contains("__cloakdropSniffer"), "collector must be idempotent across re-injection")
    }
}

@Suite("Page media state (per-page aggregator)")
struct PageMediaStateTests {
    private func envelope(_ events: [SniffEvent], top: Bool = true, frame: String = "https://site.example.com/watch") -> SniffEnvelope {
        SniffEnvelope(frameURL: frame, isTopFrame: top, events: events)
    }

    @Test func classifiesResourcesResponsesAndElementsIntoCandidates() {
        var state = PageMediaState(pageURL: "https://site.example.com/watch")
        state.apply(envelope([
            SniffEvent(kind: .resource, url: "https://cdn.example.com/vod/master.m3u8"),
            SniffEvent(kind: .response, url: "https://x.com/live?id=9", contentType: "application/dash+xml"),
            SniffEvent(kind: .element, url: "https://cdn.example.com/clip-of-the-day.mp4", tag: "video"),
            SniffEvent(kind: .resource, url: "https://cdn.example.com/app.js"),          // not media
            SniffEvent(kind: .resource, url: "https://cdn.example.com/seg00042.ts")      // segment noise
        ]))
        #expect(state.candidates.count == 3)
        #expect(state.candidates.filter { $0.type == .stream }.count == 2)
    }

    @Test func responsesFallBackToURLClassificationWhenHeadersSayNothing() {
        var state = PageMediaState()
        state.apply(envelope([
            SniffEvent(kind: .response, url: "https://cdn.example.com/movie.mkv", contentType: "application/octet-stream")
        ]))
        #expect(state.candidates.first?.type == .video)
    }

    @Test func subKilobyteResponsesAreNotResurrectedByTheURLFallback() {
        var state = PageMediaState()
        state.apply(envelope([
            SniffEvent(kind: .response, url: "https://cdn.example.com/blip.mp3",
                       contentType: "audio/mpeg", contentLength: 512)
        ]))
        #expect(state.candidates.isEmpty, "the known sub-1 KB length must gate the URL fallback too")
    }

    @Test func extensionlessPlayerSrcFallsBackToTheElementTag() {
        var state = PageMediaState()
        state.apply(envelope([
            SniffEvent(kind: .element, url: "https://site.example.com/play?id=7", tag: "audio")
        ]))
        #expect(state.candidates.first?.type == .audio)
    }

    @Test func rotatedSignedURLsOverwriteInsteadOfDuplicating() {
        var state = PageMediaState()
        state.apply(envelope([
            SniffEvent(kind: .resource, url: "https://cdn.example.com/v/movie.mp4?token=AAA"),
            SniffEvent(kind: .resource, url: "https://cdn.example.com/v/movie.mp4?token=BBB")
        ]))
        #expect(state.recordedCount == 1)
        #expect(state.candidates.first?.url.hasSuffix("token=BBB") == true, "freshest URL wins")
    }

    @Test func theStoreIsCappedButOverwritesStillLand() {
        var state = PageMediaState()
        for index in 0..<(PageMediaState.maxItems + 20) {
            state.apply(envelope([SniffEvent(kind: .resource, url: "https://cdn.example.com/f\(index).mp4")]))
        }
        #expect(state.recordedCount == PageMediaState.maxItems)
    }

    @Test func blobPlayersAndMSEEnableThePageExtractionOffer() {
        var state = PageMediaState(pageURL: "https://site.example.com/watch")
        #expect(state.pageExtractionItem == nil)
        state.apply(envelope([
            SniffEvent(kind: .element, url: "blob:https://site.example.com/uuid", tag: "video", blob: true),
            SniffEvent(kind: .page, url: "https://site.example.com/watch", title: "A Video",
                       players: [.init(video: true, area: 409_920)])
        ]))
        let pageItem = state.pageExtractionItem
        #expect(pageItem?.type == .page)
        #expect(pageItem?.extract == true)
        #expect(pageItem?.label == "A Video")
        #expect(state.candidates.first?.type == .page, "extraction offer ranks first without a stream")
    }

    @Test func aSniffedStreamSuppressesThePageOfferInCandidates() {
        var state = PageMediaState(pageURL: "https://site.example.com/watch")
        state.apply(envelope([
            SniffEvent(kind: .mse, url: "mse:video/mp4", mime: "video/mp4"),
            SniffEvent(kind: .page, url: "https://site.example.com/watch", title: "T",
                       players: [.init(video: true, area: 100_000)]),
            SniffEvent(kind: .resource, url: "https://cdn.example.com/vod/master.m3u8")
        ]))
        #expect(state.pageExtractionItem != nil, "the offer itself exists")
        #expect(state.candidates.map(\.type) == [.stream], "…but the direct stream wins the shelf")
    }

    @Test func drmKillsThePageExtractionOffer() {
        var state = PageMediaState(pageURL: "https://site.example.com/watch")
        state.apply(envelope([
            SniffEvent(kind: .mse, url: "mse:video/mp4", mime: "video/mp4"),
            SniffEvent(kind: .drm, url: "drm:com.apple.fps", keySystem: "com.apple.fps"),
            SniffEvent(kind: .page, url: "https://site.example.com/watch", title: "T",
                       players: [.init(video: true, area: 100_000)])
        ]))
        #expect(state.drmDetected)
        #expect(state.pageExtractionItem == nil)
    }

    @Test func topFrameNavigationResetsSubframeEventsDoNot() {
        var state = PageMediaState(pageURL: "https://site.example.com/watch")
        state.apply(envelope([SniffEvent(kind: .resource, url: "https://cdn.example.com/a.mp4")]))
        // A subframe navigating (an ad iframe rotating) must not wipe the page's shelf.
        state.apply(envelope([SniffEvent(kind: .navigated, url: "https://ads.example.com/next")],
                             top: false, frame: "https://ads.example.com/frame"))
        #expect(state.recordedCount == 1)
        // The top frame navigating is a new page.
        state.apply(envelope([SniffEvent(kind: .navigated, url: "https://site.example.com/next")]))
        #expect(state.recordedCount == 0)
        #expect(state.pageURL == "https://site.example.com/next")
    }

    @Test func subframeSightingsCountButSubframePageSnapshotsAreIgnored() {
        var state = PageMediaState(pageURL: "https://site.example.com/watch")
        state.apply(envelope([
            SniffEvent(kind: .resource, url: "https://cdn.example.com/embedded/master.m3u8"),
            SniffEvent(kind: .page, url: "https://player.example.com/embed", title: "Embed",
                       players: [.init(video: true, area: 1)])
        ], top: false, frame: "https://player.example.com/embed"))
        #expect(state.candidates.count == 1, "iframe media is sniffed")
        #expect(state.pageTitle.isEmpty, "iframe page state is not trusted")
        #expect(state.players.isEmpty)
    }
}

@Suite("Browser cookies (jar export)")
struct BrowserCookiesTests {
    private func cookie(
        _ name: String, _ value: String, domain: String, path: String = "/",
        secure: Bool = false, expires: Date? = nil
    ) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path
        ]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    @Test func cookieHeaderMatchesDomainPathSecureAndExpiry() throws {
        let url = URL(string: "https://www.example.com/videos/page")!
        let jar = [
            cookie("sid", "1", domain: ".example.com"),                                   // domain match
            cookie("host", "2", domain: "www.example.com"),                               // exact host
            cookie("other", "3", domain: "other.com"),                                    // wrong site
            cookie("deep", "4", domain: ".example.com", path: "/videos"),                 // path prefix
            cookie("elsewhere", "5", domain: ".example.com", path: "/admin"),             // wrong path
            cookie("expired", "6", domain: ".example.com", expires: .distantPast),        // expired
            cookie("secure", "7", domain: ".example.com", secure: true)                   // https → sent
        ]
        let header = try #require(BrowserCookies.cookieHeader(for: url, from: jar))
        #expect(header.contains("sid=1"))
        #expect(header.contains("host=2"))
        #expect(header.contains("deep=4"))
        #expect(header.contains("secure=7"))
        #expect(!header.contains("other=3"))
        #expect(!header.contains("elsewhere=5"))
        #expect(!header.contains("expired=6"))

        let insecure = URL(string: "http://www.example.com/videos/page")!
        let insecureHeader = try #require(BrowserCookies.cookieHeader(for: insecure, from: jar))
        #expect(!insecureHeader.contains("secure=7"), "Secure cookies never ride plain http")
    }

    @Test func hostOnlyCookiesDoNotLeakToSubdomains() {
        let jar = [cookie("host", "2", domain: "example.com")]
        #expect(BrowserCookies.cookieHeader(for: URL(string: "https://sub.example.com/")!, from: jar) == nil)
        #expect(BrowserCookies.cookieHeader(for: URL(string: "https://example.com/")!, from: jar) != nil)
    }

    @Test func netscapeFileCarriesTheJarWithScopingIntact() throws {
        // Foundation caps cookie lifetimes (~400 days), so derive the expected stamp from the
        // cookie it actually built rather than the date we asked for.
        let persistent = cookie("sid", "abc", domain: ".youtube.com", secure: true,
                                expires: Date().addingTimeInterval(86_400 * 30))
        let stamp = Int(try #require(persistent.expiresDate).timeIntervalSince1970)
        let text = BrowserCookies.netscapeFile([
            persistent,
            cookie("session", "xyz", domain: "accounts.google.com", path: "/auth")        // session cookie
        ])
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines[0] == "# Netscape HTTP Cookie File", "yt-dlp requires the magic first line")
        #expect(lines[1] == ".youtube.com\tTRUE\t/\tTRUE\t\(stamp)\tsid\tabc")
        #expect(lines[2] == "accounts.google.com\tFALSE\t/auth\tFALSE\t0\tsession\txyz")
    }

    @Test func fieldsThatWouldBreakTheFormatDropTheCookie() {
        let text = BrowserCookies.netscapeFile([
            cookie("bad", "tab\there", domain: ".example.com"),
            cookie("good", "clean", domain: ".example.com")
        ])
        #expect(!text.contains("bad"))
        #expect(text.contains("good\tclean"))
    }
}
