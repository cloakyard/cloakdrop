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
          {"kind":"element","url":"https://cdn.example.com/movie.mp4","tag":"video","duration":12.5,"area":921600},
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
        #expect(envelope.events[2].area == 921_600)
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

    @Test func classifiesResourcesResponsesAndElementsAndSelectsOnePrimaryCandidate() {
        var state = PageMediaState(pageURL: "https://site.example.com/watch")
        state.apply(envelope([
            SniffEvent(kind: .resource, url: "https://cdn.example.com/vod/master.m3u8"),
            SniffEvent(kind: .response, url: "https://x.com/live?id=9", contentType: "application/dash+xml"),
            SniffEvent(kind: .element, url: "https://cdn.example.com/clip-of-the-day.mp4", tag: "video"),
            SniffEvent(kind: .resource, url: "https://cdn.example.com/app.js"),          // not media
            SniffEvent(kind: .resource, url: "https://cdn.example.com/seg00042.ts")      // segment noise
        ]))
        #expect(state.recordedCount == 3, "all plausible sightings remain available to the selector")
        #expect(state.candidates.count == 1, "the browser shelf exposes one primary grab")
        #expect(state.candidates.first?.type == .page, "unrelated manifests are resolved instead of guessed")
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

    @Test("Known video sites use one extractor grab and discard player/ad resources")
    func knownVideoSiteUsesExtractorOnly() throws {
        var state = PageMediaState(pageURL: "https://www.youtube.com/watch?v=BaW_jenozKc")
        state.apply(envelope([
            SniffEvent(kind: .resource, url: "https://r1---sn.example.googlevideo.com/videoplayback?id=main"),
            SniffEvent(kind: .resource, url: "https://imasdk.googleapis.com/video/preroll.mp4"),
            SniffEvent(kind: .resource, url: "https://fallback-cdn.example.com/player/master.m3u8"),
            SniffEvent(kind: .mse, url: "mse:video/mp4", mime: "video/mp4"),
            SniffEvent(kind: .page, url: "https://www.youtube.com/watch?v=BaW_jenozKc",
                       blob: true, title: "yt-dlp test video", players: [.init(video: true, area: 854 * 480)])
        ]))
        let item = try #require(state.candidates.only)
        #expect(item.type == .page)
        #expect(item.extract)
        #expect(item.url == "https://www.youtube.com/watch?v=BaW_jenozKc")
    }

    @Test("Mainstream video-site watch routes always reduce to one page grab")
    func mainstreamVideoSiteCorpus() throws {
        let pages = [
            "https://vimeo.com/76979871",
            "https://www.twitch.tv/videos/123456",
            "https://www.dailymotion.com/video/x9abcde",
            "https://soundcloud.com/creator/track-name",
            "https://www.bilibili.com/video/BV1gi4y1V7Xx"
        ]
        for page in pages {
            var state = PageMediaState(pageURL: page)
            state.apply(envelope([
                SniffEvent(kind: .resource, url: "https://cdn.example.com/preroll/ad.mp4"),
                SniffEvent(kind: .resource, url: "https://cdn.example.com/program/master.m3u8"),
                SniffEvent(kind: .page, url: page, blob: true, title: "Program",
                           players: [.init(video: true, area: 1280 * 720)])
            ], frame: page))
            let item = try #require(state.candidates.only, "\(page) did not produce exactly one grab")
            #expect(item.type == .page, "\(page) should go through the resolver")
            #expect(item.url == page)
        }
    }

    @Test("Additional live-verified media routes reduce to one extractor grab")
    func expandedVideoSiteCorpus() throws {
        let pages = [
            "https://rumble.com/embed/v5pv5f",
            "https://odysee.com/@channel:1/video:e",
            "https://www.ted.com/talks/a_public_talk",
            "https://www.loom.com/share/43d05f362f734614a2e81b4694a3a523",
            "https://medal.tv/games/valorant/clips/jTBFnLKdLy15K",
            "https://www.nicovideo.jp/watch/sm8628149",
            "https://artist.bandcamp.com/track/a-song",
            "https://www.mixcloud.com/artist/a-mix/",
            "https://kick.com/user?clip=clip_123",
            "https://vk.com/video205387401_165548505",
            "https://www.snapchat.com/spotlight/ABC123",
            "https://streamable.com/dnd1",
            "https://rutube.ru/video/3eac3b4561676c17df9132a9a1e62e3e/",
            "https://www.acfun.cn/v/ac35457073",
            "https://www.hidive.com/stream/show/s01e001",
        ]
        for page in pages {
            let state = PageMediaState(pageURL: page)
            let item = try #require(state.candidates.only, "\(page) did not produce exactly one grab")
            #expect(item.type == .page)
            #expect(item.url == page)
        }
    }

    @Test("Mixed and unreliable social sites prefer one observed program URL over their page endpoint")
    func observedFirstSitesUsePrimaryProgram() throws {
        let cases = [
            "https://www.tiktok.com/@creator/video/123456",
            "https://www.facebook.com/reel/123456",
            "https://x.com/creator/status/123456",
            "https://www.instagram.com/reel/ABC123/",
            "https://www.reddit.com/r/videos/comments/abc123/title/",
            "https://www.linkedin.com/posts/creator_video-activity-7151241570371948544",
            "https://bsky.app/profile/creator.example/post/3l3vgf77uco2g",
        ]
        for page in cases {
            var state = PageMediaState(pageURL: page)
            state.apply(envelope([
                SniffEvent(kind: .page, url: page, players: [.init(video: true, area: 1280 * 720)]),
                SniffEvent(kind: .element, url: "https://ads.example.com/preroll/creative.mp4",
                           tag: "video", duration: 15),
                SniffEvent(kind: .element, url: "https://first-party-cdn.example/program.mp4",
                           tag: "video", duration: 600),
            ], frame: page))

            let item = try #require(state.candidates.only)
            #expect(item.type == .video)
            #expect(item.url.hasSuffix("program.mp4"))
        }
    }

    @Test("A mixed social-post route appears only after actual media activity")
    func mixedPostRequiresObservedMedia() throws {
        let page = "https://x.com/creator/status/123456"
        var state = PageMediaState(pageURL: page)
        #expect(state.candidates.isEmpty, "a text/image-only post must not show a fake video grab")

        state.apply(envelope([
            SniffEvent(kind: .page, url: page, blob: true, title: "Post video",
                       players: [.init(video: true, area: 1280 * 720)])
        ], frame: page))
        let item = try #require(state.candidates.only)
        #expect(item.type == .page)
        #expect(item.url == page)
    }

    @Test("A Bilibili anime watch page resolves as one extractor item")
    func bilibiliAnimeUsesSinglePageExtraction() throws {
        let page = "https://www.bilibili.com/bangumi/play/ep100643"
        var state = PageMediaState(pageURL: page)
        state.apply(envelope([
            SniffEvent(kind: .resource, url: "https://content.example.com/episode/master.m3u8"),
            SniffEvent(kind: .resource, url: "https://ads.example.net/preroll/creative.mp4"),
            SniffEvent(kind: .page, url: page, blob: true, title: "Episode 1",
                       players: [.init(video: true, area: 1280 * 720)])
        ], frame: page))
        let item = try #require(state.candidates.only)
        #expect(item.type == .page)
        #expect(item.url == page)
    }

    @Test("DRM on the primary anime player suppresses every media grab")
    func primaryPlayerDRMSuppressesMedia() {
        let page = "https://www.hidive.com/video/123456"
        var state = PageMediaState(pageURL: page)
        state.apply(envelope([
            SniffEvent(kind: .page, url: page, blob: true, title: "Protected episode",
                       players: [.init(video: true, area: 1280 * 720)]),
            SniffEvent(kind: .drm, url: "drm:mediakeys"),
            SniffEvent(kind: .resource, url: "https://content.example.com/episode/master.m3u8")
        ], frame: page))
        #expect(state.drmDetected)
        #expect(state.candidates.isEmpty)
    }

    @Test("A small DRM ad iframe cannot poison a larger clear embedded player")
    func adFrameDRMDoesNotPoisonPrimaryPlayer() throws {
        let page = "https://watch.example.com/episode/1"
        var state = PageMediaState(pageURL: page)
        state.apply(envelope([
            SniffEvent(kind: .page, url: page, title: "Episode 1", players: [])
        ], frame: page))
        state.apply(envelope([
            SniffEvent(kind: .page, url: "https://ad-player.example/frame",
                       players: [.init(video: true, area: 300 * 169)]),
            SniffEvent(kind: .drm, url: "drm:mediakeys"),
            SniffEvent(kind: .resource, url: "https://unknown-cdn.example/promo.mp4")
        ], top: false, frame: "https://ad-player.example/frame"))
        state.apply(envelope([
            SniffEvent(kind: .page, url: "https://player.example/embed/episode-1",
                       players: [.init(video: true, area: 1280 * 720)]),
            SniffEvent(kind: .resource, url: "https://media.example.com/episode-1/master.m3u8")
        ], top: false, frame: "https://player.example/embed/episode-1"))

        #expect(!state.drmDetected)
        let item = try #require(state.candidates.only)
        #expect(item.url.contains("episode-1/master.m3u8"))
    }

    @Test("The largest embedded player wins over a generic-CDN video ad")
    func largestPlayerFrameWins() throws {
        var state = PageMediaState(pageURL: "https://anime.example/watch/42")
        state.apply(envelope([
            SniffEvent(kind: .page, url: "https://promo-player.example/embed",
                       players: [.init(video: true, area: 300 * 169)]),
            SniffEvent(kind: .element, url: "https://neutral-cdn.example/promo-spot.mp4",
                       tag: "video", duration: 20)
        ], top: false, frame: "https://promo-player.example/embed"))
        state.apply(envelope([
            SniffEvent(kind: .page, url: "https://episode-player.example/embed/42",
                       players: [.init(video: true, area: 1280 * 720)]),
            SniffEvent(kind: .resource, url: "https://stream.example.com/show/42/master.m3u8"),
            SniffEvent(kind: .resource, url: "https://stream.example.com/show/42/720p/index.m3u8")
        ], top: false, frame: "https://episode-player.example/embed/42"))

        let item = try #require(state.candidates.only)
        #expect(item.type == .stream)
        #expect(item.url.contains("show/42/master.m3u8"))
        #expect(!item.url.contains("promo"))
    }

    @Test("Unmarked ad/program streams in one player resolve the page instead of guessing")
    func ambiguousStreamsUsePageExtraction() throws {
        let frame = "https://player.example/embed/42"
        var state = PageMediaState(pageURL: "https://watch.example.com/42")
        state.apply(envelope([
            SniffEvent(kind: .page, url: frame, players: [.init(video: true, area: 1280 * 720)]),
            // Neither URL has an ad marker: ordering cannot distinguish pre-roll from post-roll.
            SniffEvent(kind: .response, url: "https://cdn-one.example/v/first.m3u8",
                       contentType: "application/vnd.apple.mpegurl", contentLength: 2_000),
            SniffEvent(kind: .response, url: "https://cdn-two.example/v/episode-42.m3u8",
                       contentType: "application/vnd.apple.mpegurl", contentLength: 2_000)
        ], top: false, frame: frame))

        let item = try #require(state.candidates.only)
        #expect(item.type == .page)
        #expect(item.url == "https://watch.example.com/42")
    }

    @Test("A marked roll stream is removed and leaves the one program master")
    func markedRollLeavesDirectProgram() throws {
        let page = "https://watch.example.com/42"
        var state = PageMediaState(pageURL: page)
        state.apply(envelope([
            SniffEvent(kind: .page, url: page, players: [.init(video: true, area: 1280 * 720)]),
            SniffEvent(kind: .response, url: "https://cdn.example.com/preroll/spot.m3u8",
                       contentType: "application/vnd.apple.mpegurl"),
            SniffEvent(kind: .response, url: "https://cdn.example.com/show/42/master.m3u8",
                       contentType: "application/vnd.apple.mpegurl"),
        ], frame: page))

        let item = try #require(state.candidates.only)
        #expect(item.type == .stream)
        #expect(item.url.contains("show/42/master.m3u8"))
    }

    @Test("Multiple direct videos reduce to the longest primary-player source")
    func longestElementSourceWins() throws {
        let page = "https://video.example.com/watch/1"
        var state = PageMediaState(pageURL: page)
        state.apply(envelope([
            SniffEvent(kind: .page, url: page, players: [.init(video: true, area: 1280 * 720)]),
            SniffEvent(kind: .element, url: "https://cdn.example.com/preview.mp4", tag: "video", duration: 15),
            SniffEvent(kind: .element, url: "https://cdn.example.com/feature.mp4", tag: "video", duration: 5_400),
            SniffEvent(kind: .element, url: "https://cdn.example.com/bumper.mp4", tag: "video", duration: 5)
        ], frame: page))

        let item = try #require(state.candidates.only)
        #expect(item.url.hasSuffix("feature.mp4"))
    }

    @Test("Player area breaks a same-frame tie instead of last-loaded order")
    func largestElementSourceWinsWithoutDuration() throws {
        let page = "https://social.example.com/post/1"
        var state = PageMediaState(pageURL: page)
        state.apply(envelope([
            SniffEvent(kind: .page, url: page, players: [
                .init(video: true, area: 1280 * 720), .init(video: true, area: 240 * 135)
            ]),
            SniffEvent(kind: .element, url: "https://cdn.example.com/main.mp4", tag: "video", area: 1280 * 720),
            SniffEvent(kind: .element, url: "https://cdn.example.com/late-preview.mp4", tag: "video", area: 240 * 135)
        ], frame: page))

        let item = try #require(state.candidates.only)
        #expect(item.url.hasSuffix("main.mp4"))
    }

    @Test("Download-site responses surface only the explicit attachment")
    func downloadSiteAttachmentWins() throws {
        let page = "https://downloads.example.com/project/releases"
        var state = PageMediaState(pageURL: page)
        state.apply(envelope([
            SniffEvent(kind: .resource, url: "https://cdn.example.com/promo.mp4"),
            SniffEvent(kind: .response, url: "https://objects.example.com/releases/asset?id=7",
                       contentType: "application/octet-stream", contentLength: 25_000_000,
                       contentDisposition: "attachment; filename=Project-2.0.dmg")
        ], frame: page))

        let item = try #require(state.candidates.only)
        #expect(item.type == .file)
        #expect(item.filename == "Project-2.0.dmg")
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
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
