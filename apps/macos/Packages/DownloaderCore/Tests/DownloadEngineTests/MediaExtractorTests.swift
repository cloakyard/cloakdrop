import Testing
import Foundation
import DownloadModels
@testable import DownloadEngine

/// yt-dlp `-J`-style output: a progressive 360p, video-only 1080p in both mp4 and webm, a video-only
/// 4K webm, separate m4a + opus audio, and an HLS format that must NOT become a direct-download tier.
private let sampleJSON = #"""
{
  "title": "My Video: Test/Clip",
  "id": "abc123",
  "webpage_url": "https://www.youtube.com/watch?v=abc123",
  "extractor_key": "Youtube",
  "is_live": false,
  "formats": [
    { "format_id": "18",  "url": "https://v/18",  "ext": "mp4",  "vcodec": "avc1.42001E", "acodec": "mp4a.40.2", "width": 640,  "height": 360,  "tbr": 700,   "http_headers": { "User-Agent": "UA-progressive", "Cookie": "X=1" } },
    { "format_id": "137", "url": "https://v/137", "ext": "mp4",  "vcodec": "avc1.640028", "acodec": "none",      "width": 1920, "height": 1080, "fps": 30, "tbr": 4000,  "http_headers": { "User-Agent": "UA-video1080" } },
    { "format_id": "248", "url": "https://v/248", "ext": "webm", "vcodec": "vp9",         "acodec": "none",      "width": 1920, "height": 1080, "fps": 30, "tbr": 3500,  "http_headers": { "User-Agent": "UA-webm1080" } },
    { "format_id": "313", "url": "https://v/313", "ext": "webm", "vcodec": "vp09.00.50",  "acodec": "none",      "width": 3840, "height": 2160, "fps": 30, "tbr": 20000, "filesize_approx": 123456789.0, "http_headers": { "User-Agent": "UA-4k" } },
    { "format_id": "140", "url": "https://a/140", "ext": "m4a",  "vcodec": "none",        "acodec": "mp4a.40.2", "abr": 128,   "http_headers": { "User-Agent": "UA-m4a" } },
    { "format_id": "251", "url": "https://a/251", "ext": "webm", "vcodec": "none",        "acodec": "opus",      "abr": 160,   "http_headers": { "User-Agent": "UA-opus" } },
    { "format_id": "hls", "url": "https://v/master.m3u8", "ext": "mp4", "protocol": "m3u8_native", "vcodec": "avc1.4d401f", "acodec": "mp4a.40.2", "height": 720 }
  ]
}
"""#

@Suite("Media extraction — parse")
struct MediaExtractionParseTests {
    @Test func parsesFormatsAndClassifiesTracks() throws {
        let media = try ExtractedMedia.parse(json: Data(sampleJSON.utf8))
        #expect(media.title == "My Video_ Test_Clip")     // sanitized ":" and "/"
        #expect(media.extractor == "Youtube")
        #expect(media.formats.count == 7)

        let progressive = try #require(media.formats.first { $0.formatID == "18" })
        #expect(progressive.isProgressive)
        #expect(progressive.height == 360)
        #expect(progressive.httpHeaders["Cookie"] == "X=1")

        let videoOnly = try #require(media.formats.first { $0.formatID == "137" })
        #expect(videoOnly.isVideoOnly)
        #expect(videoOnly.fps == 30)

        let audioOnly = try #require(media.formats.first { $0.formatID == "251" })
        #expect(audioOnly.isAudioOnly)
        #expect(audioOnly.abr == 160)

        // filesize_approx given as a JSON float still parses to Int64.
        let fourK = try #require(media.formats.first { $0.formatID == "313" })
        #expect(fourK.filesize == 123456789)
    }

    @Test func directFormatsExcludeManifestProtocols() throws {
        let media = try ExtractedMedia.parse(json: Data(sampleJSON.utf8))
        #expect(media.directFormats.allSatisfy { $0.formatID != "hls" })   // m3u8_native dropped
        #expect(media.formats.contains { $0.formatID == "hls" })           // but still present in the raw list
    }

    @Test("A direct video with omitted codecs remains grabbable")
    func codecOmittedDirectVideoIsProgressive() throws {
        let json = #"""
        { "title": "Vimeo clip", "formats": [
          { "format_id": "http-720p", "url": "https://vod.example/video.mp4", "ext": "mp4",
            "protocol": "https", "width": 1280, "height": 720 },
          { "format_id": "http-unknown", "url": "https://video.example/content?id=7", "ext": "mp4",
            "protocol": "https" },
          { "format_id": "hls-720p", "url": "https://vod.example/video.m3u8", "ext": "mp4",
            "protocol": "m3u8_native", "width": 1280, "height": 720 }
        ] }
        """#
        let media = try ExtractedMedia.parse(json: Data(json.utf8))
        let direct = try #require(media.formats.first { $0.formatID == "http-720p" })
        let dimensionless = try #require(media.formats.first { $0.formatID == "http-unknown" })
        let manifest = try #require(media.formats.first { $0.formatID == "hls-720p" })

        #expect(direct.isProgressive)
        #expect(dimensionless.isProgressive, "a declared direct MP4 needs no codec/dimension metadata")
        #expect(media.directFormats.map(\.formatID) == ["http-720p", "http-unknown"])
        #expect(!manifest.hasVideo && !manifest.hasAudio, "manifest codec omissions are never inferred")
        let stream = try #require(media.toMediaStream(pageURL: URL(string: "https://vimeo.example/1")!))
        #expect(stream.variants.map(\.id) == ["http-720p", "http-unknown"])
        #expect(stream.variants[0].audioGroupID == nil)
    }

    @Test("HLS-only extraction chooses one highest-quality manifest for the app resolver")
    func hlsOnlyExtractionChoosesOneManifest() throws {
        let json = #"""
        { "title": "AcFun episode", "formats": [
          { "format_id": "360p", "url": "https://cdn.example/360/index.m3u8", "ext": "mp4",
            "protocol": "m3u8_native", "width": 640, "height": 360, "tbr": 700 },
          { "format_id": "master", "url": "https://cdn.example/master.m3u8", "ext": "mp4",
            "protocol": "m3u8_native", "http_headers": { "Referer": "https://www.acfun.cn/" } },
          { "format_id": "1080p-low", "url": "https://cdn.example/1080-low/index.m3u8", "ext": "mp4",
            "protocol": "m3u8_native", "width": 1920, "height": 1080, "tbr": 2500 },
          { "format_id": "1080p-high", "url": "https://cdn.example/1080-high/index.m3u8", "ext": "mp4",
            "protocol": "m3u8_native", "width": 1920, "height": 1080, "tbr": 5000,
            "http_headers": { "Referer": "https://www.acfun.cn/" } }
        ] }
        """#
        let media = try ExtractedMedia.parse(json: Data(json.utf8))

        #expect(media.toMediaStream(pageURL: URL(string: "https://www.acfun.cn/v/ac1")!) == nil)
        #expect(media.preferredManifestFormat?.formatID == "1080p-high")
        #expect(media.downloadHeaders["Referer"] == "https://www.acfun.cn/")
    }

    @Test func invalidOutputThrows() {
        #expect(throws: MediaExtractionError.invalidOutput) {
            try ExtractedMedia.parse(json: Data("not json at all".utf8))
        }
    }
}

@Suite("Media extraction — mapping to MediaStream")
struct MediaExtractionMappingTests {
    private func stream() throws -> MediaStream {
        let media = try ExtractedMedia.parse(json: Data(sampleJSON.utf8))
        return try #require(media.toMediaStream(pageURL: URL(string: "https://www.youtube.com/watch?v=abc123")!))
    }

    @Test func onethierPerHeightSortedHighFirst() throws {
        let heights = try stream().variants.map { $0.resolution?.height }
        #expect(heights == [2160, 1080, 360])   // one tier per resolution, 4K first
    }

    @Test func prefersCheapestToAssembleAtEachHeight() throws {
        let s = try stream()
        // 1080p exists as mp4 (137) and webm (248) — the mp4 (AVFoundation-muxable) wins.
        let hd = try #require(s.variants.first { $0.resolution?.height == 1080 })
        #expect(hd.id == "137")
        // 360p is progressive (already muxed) — no separate audio needed.
        let sd = try #require(s.variants.first { $0.resolution?.height == 360 })
        #expect(sd.id == "18")
        #expect(sd.audioGroupID == nil)
    }

    @Test func pairsAudioByContainerFamily() throws {
        let s = try stream()
        // mp4 1080p video pairs with the m4a audio; webm 4K video pairs with the opus audio.
        let hd = try #require(s.variants.first { $0.id == "137" })
        #expect(hd.audioGroupID == "140")
        let uhd = try #require(s.variants.first { $0.id == "313" })
        #expect(uhd.audioGroupID == "251")
        #expect(s.format == .dash)
        #expect(s.audioTracks.map(\.id).sorted() == ["140", "251"])
    }

    @Test func bestVariantIsHighestResolution() throws {
        let s = try stream()
        #expect(s.bestVariant?.id == "313")   // 4K, highest bandwidth
    }

    @Test func planForBestTierCarriesContainerMatchedAudio() throws {
        let s = try stream()
        let best = try #require(s.bestVariant)                                  // 313 (4K webm)
        let audio = s.audioTracks.first { $0.groupID == best.audioGroupID }      // opus 251
        let plan = s.plan(for: best, audio: audio)
        #expect(plan.hasSeparateAudio)
        #expect(plan.segments.first?.url == URL(string: "https://v/313"))
        #expect(plan.audioSegments?.first?.url == URL(string: "https://a/251"))
    }

    @Test func progressiveTierPlanHasNoSeparateAudio() throws {
        let s = try stream()
        let sd = try #require(s.variants.first { $0.id == "18" })
        let plan = s.plan(for: sd, audio: nil)
        #expect(!plan.hasSeparateAudio)
        #expect(plan.segments.first?.url == URL(string: "https://v/18"))
    }

    @Test func audioOnlyPageYieldsNoTiers() throws {
        // A page whose only direct formats are audio (or manifests) can't produce a video tier.
        let audioOnly = #"""
        { "title": "song", "formats": [
          { "format_id": "a", "url": "https://a/1", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "abr": 128 }
        ] }
        """#
        let media = try ExtractedMedia.parse(json: Data(audioOnly.utf8))
        #expect(media.toMediaStream(pageURL: URL(string: "https://x/y")!) == nil)
    }

    @Test func containerFamilyPairingHelper() {
        let m4a = ExtractedFormat(formatID: "a", url: URL(string: "https://a/m4a")!, ext: "m4a", acodec: "mp4a", abr: 128)
        let opus = ExtractedFormat(formatID: "b", url: URL(string: "https://a/opus")!, ext: "webm", acodec: "opus", abr: 160)
        #expect(ExtractedMedia.bestAudio(forVideoExt: "mp4", from: [m4a, opus])?.formatID == "a")
        #expect(ExtractedMedia.bestAudio(forVideoExt: "webm", from: [m4a, opus])?.formatID == "b")
    }
}

private final class SequencedProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ProcessRunResult]
    private var recordedArguments: [[String]] = []

    init(_ results: [ProcessRunResult]) {
        self.results = results
    }

    var allArguments: [[String]] { lock.withLock { recordedArguments } }

    func run(executable: URL, arguments: [String], timeout: Duration) async throws -> ProcessRunResult {
        lock.withLock {
            recordedArguments.append(arguments)
            guard !results.isEmpty else {
                return ProcessRunResult(
                    exitCode: 127, stdout: Data(), stderr: Data("unexpected extra process call".utf8)
                )
            }
            return results.removeFirst()
        }
    }
}

@Suite("Media extraction — YtDlpExtractor over a mock process")
struct YtDlpExtractorTests {
    private let fakeBinary = URL(fileURLWithPath: "/usr/bin/true")
    private let page = URL(string: "https://www.youtube.com/watch?v=abc123")!

    @Test func buildsExpectedArgumentsAndParses() async throws {
        let runner = MockProcessRunner(json: sampleJSON)
        let extractor = YtDlpExtractor(executableURL: fakeBinary, runner: runner)
        let media = try await extractor.extract(pageURL: page, cookies: .header("SID=abc"), userAgent: "UA/1")

        #expect(media.formats.count == 7)
        let args = runner.lastArguments
        #expect(args.contains("-J"))
        #expect(args.contains("--no-playlist"))
        #expect(args.contains("--user-agent"))
        #expect(args.contains("UA/1"))
        #expect(args.contains("--add-header"))
        #expect(args.contains("Cookie:SID=abc"))
        #expect(args.last == page.absoluteString)
    }

    @Test func aCookiesFilePassesTheNetscapeJarPath() async throws {
        let runner = MockProcessRunner(json: sampleJSON)
        let extractor = YtDlpExtractor(executableURL: fakeBinary, runner: runner)
        let jar = URL(fileURLWithPath: "/tmp/cloakdrop-jar/cookies.txt")
        _ = try await extractor.extract(pageURL: page, cookies: .file(jar), userAgent: nil)
        let args = runner.lastArguments
        #expect(args.contains("--cookies"))
        #expect(args.contains(jar.path))
        #expect(!args.contains("--add-header"), "a jar replaces the flattened header, never joins it")
    }

    @Test func omitsCookieAndUAWhenNotProvided() async throws {
        let runner = MockProcessRunner(json: sampleJSON)
        let extractor = YtDlpExtractor(executableURL: fakeBinary, runner: runner)
        _ = try await extractor.extract(pageURL: page, cookies: nil, userAgent: nil)
        #expect(!runner.lastArguments.contains("--add-header"))
        #expect(!runner.lastArguments.contains("--user-agent"))
        #expect(!runner.lastArguments.contains("--cookies"))
    }

    @Test func nonzeroExitSurfacesStderrTail() async {
        let runner = MockProcessRunner(exitCode: 1, stderr: Data("ERROR: Sign in to confirm you're not a bot".utf8))
        let extractor = YtDlpExtractor(executableURL: fakeBinary, runner: runner)
        do {
            _ = try await extractor.extract(pageURL: page, cookies: nil, userAgent: nil)
            Issue.record("expected an error")
        } catch let error as MediaExtractionError {
            guard case let .failed(message) = error else { Issue.record("wrong case: \(error)"); return }
            #expect(message.contains("bot"))
        } catch { Issue.record("unexpected: \(error)") }
    }

    @Test("A failed public Vimeo page retries the equivalent first-party player URL")
    func vimeoPublicPageFallback() async throws {
        let runner = SequencedProcessRunner([
            ProcessRunResult(exitCode: 1, stdout: Data(), stderr: Data("HTTP Error 401".utf8)),
            ProcessRunResult(exitCode: 0, stdout: Data(sampleJSON.utf8), stderr: Data()),
        ])
        let extractor = YtDlpExtractor(executableURL: fakeBinary, runner: runner)
        let page = URL(string: "https://vimeo.com/channels/staffpicks/76979871")!

        _ = try await extractor.extract(pageURL: page, cookies: nil, userAgent: "Safari/18")

        #expect(runner.allArguments.count == 2)
        #expect(runner.allArguments[0].last == page.absoluteString)
        #expect(runner.allArguments[1].last == "https://player.vimeo.com/video/76979871")
        #expect(runner.allArguments[1].contains("Safari/18"))
    }

    @Test("Private/hash Vimeo routes are never rewritten by the public-player fallback")
    func vimeoPrivateRouteDoesNotFallback() async {
        let runner = SequencedProcessRunner([
            ProcessRunResult(exitCode: 1, stdout: Data(), stderr: Data("private video".utf8)),
            ProcessRunResult(exitCode: 0, stdout: Data(sampleJSON.utf8), stderr: Data()),
        ])
        let extractor = YtDlpExtractor(executableURL: fakeBinary, runner: runner)
        let privatePage = URL(string: "https://vimeo.com/76979871/privatehash")!

        await #expect(throws: MediaExtractionError.self) {
            _ = try await extractor.extract(pageURL: privatePage, cookies: nil, userAgent: nil)
        }
        #expect(runner.allArguments.count == 1)
    }

    @Test func emptyOutputIsInvalid() async {
        let runner = MockProcessRunner(exitCode: 0, stdout: Data())
        let extractor = YtDlpExtractor(executableURL: fakeBinary, runner: runner)
        await #expect(throws: MediaExtractionError.invalidOutput) {
            _ = try await extractor.extract(pageURL: page, cookies: nil, userAgent: nil)
        }
    }

    @Test func propagatesRunnerTimeout() async {
        let runner = MockProcessRunner(throwing: .timedOut)
        let extractor = YtDlpExtractor(executableURL: fakeBinary, runner: runner)
        await #expect(throws: MediaExtractionError.timedOut) {
            _ = try await extractor.extract(pageURL: page, cookies: nil, userAgent: nil)
        }
    }

    @Test func versionTrimsAndReturns() async {
        let runner = MockProcessRunner(exitCode: 0, stdout: Data("2026.06.09\n".utf8))
        let extractor = YtDlpExtractor(executableURL: fakeBinary, runner: runner)
        let version = await extractor.version()
        #expect(version == "2026.06.09")
        #expect(runner.lastArguments == ["--version"])
    }
}

// yt-dlp `-J` output with authored subtitles (en, es), plus automatic captions (en which is redundant,
// fr which is common, and "zzz" which isn't a common language). "en" also offers a json3 variant we
// can't convert, so the vtt must win.
private let subtitleJSON = #"""
{
  "title": "Subtitled Clip",
  "id": "sub1",
  "formats": [
    { "format_id": "18", "url": "https://v/18", "ext": "mp4", "vcodec": "avc1", "acodec": "mp4a", "width": 640, "height": 360, "tbr": 700 }
  ],
  "subtitles": {
    "en": [ { "ext": "json3", "url": "https://s/en.json3" }, { "ext": "vtt", "url": "https://s/en.vtt", "name": "English" } ],
    "es": [ { "ext": "vtt", "url": "https://s/es.vtt", "name": "Spanish" } ]
  },
  "automatic_captions": {
    "en": [ { "ext": "vtt", "url": "https://s/en.auto.vtt" } ],
    "fr": [ { "ext": "vtt", "url": "https://s/fr.auto.vtt" } ],
    "zzz": [ { "ext": "vtt", "url": "https://s/zzz.auto.vtt" } ]
  }
}
"""#

@Suite("Media extraction — subtitles")
struct MediaExtractionSubtitleTests {
    @Test("Authored subtitles are parsed, preferring a convertible format over json3")
    func parsesAuthoredSubtitles() throws {
        let media = try ExtractedMedia.parse(json: Data(subtitleJSON.utf8))
        let en = try #require(media.subtitles.first { $0.language == "en" })
        #expect(en.isAutomatic == false)
        #expect(en.ext == "vtt")                                   // json3 rejected in favour of vtt
        #expect(en.url.absoluteString == "https://s/en.vtt")
        #expect(en.name == "English")
    }

    @Test("Automatic captions fill only common languages not already authored")
    func boundsAutomaticCaptions() throws {
        let media = try ExtractedMedia.parse(json: Data(subtitleJSON.utf8))
        let languages = media.subtitles.map(\.language)
        #expect(languages.contains("en"))                          // authored
        #expect(languages.contains("es"))                          // authored
        #expect(languages.contains("fr"))                          // automatic, common → kept
        #expect(!languages.contains("zzz"))                        // automatic, uncommon → dropped
        // The "en" automatic caption must not duplicate the authored one.
        #expect(media.subtitles.filter { $0.language == "en" }.count == 1)
        #expect(try #require(media.subtitles.first { $0.language == "en" }).isAutomatic == false)
    }

    @Test("Automatic captions are tagged (auto) in the mapped subtitle track label")
    func mapsSubtitlesIntoStreamTracks() throws {
        let media = try ExtractedMedia.parse(json: Data(subtitleJSON.utf8))
        let stream = try #require(media.toMediaStream(pageURL: URL(string: "https://x/watch")!))
        #expect(stream.subtitleTracks.count == 3)                  // en, es, fr
        let fr = try #require(stream.subtitleTracks.first { $0.language == "fr" })
        #expect(fr.name?.contains("(auto)") == true)
        // Each maps to a resolved single-segment track, ready to plan without a further fetch.
        #expect(fr.asSubtitle?.segments.count == 1)
        let en = try #require(stream.subtitleTracks.first { $0.language == "en" })
        #expect(en.name == "English")                              // authored → no (auto) tag
    }

    @Test("A page with no subtitle maps to a stream with none")
    func noSubtitlesIsEmpty() throws {
        let media = try ExtractedMedia.parse(json: Data(sampleJSON.utf8))
        #expect(media.subtitles.isEmpty)
        let stream = try #require(media.toMediaStream(pageURL: URL(string: "https://x/watch")!))
        #expect(stream.subtitleTracks.isEmpty)
    }
}

// A dubbed page: one video tier plus two audio-only formats tagged with different languages.
private let dubbedJSON = #"""
{
  "title": "Dubbed Clip",
  "id": "dub1",
  "formats": [
    { "format_id": "137", "url": "https://v/137", "ext": "mp4", "vcodec": "avc1.640028", "acodec": "none", "width": 1920, "height": 1080, "tbr": 4000 },
    { "format_id": "en",  "url": "https://a/en",  "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "abr": 128, "language": "en" },
    { "format_id": "es",  "url": "https://a/es",  "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "abr": 128, "language": "es" }
  ]
}
"""#

@Suite("Media extraction — multi-audio")
struct MediaExtractionAudioLanguageTests {
    @Test("Audio-format languages are captured and surfaced as labelled audio tracks")
    func capturesAudioLanguages() throws {
        let media = try ExtractedMedia.parse(json: Data(dubbedJSON.utf8))
        #expect(media.formats.first { $0.formatID == "es" }?.language == "es")
        let stream = try #require(media.toMediaStream(pageURL: URL(string: "https://x/watch")!))
        let languages = Set(stream.audioTracks.compactMap(\.language))
        #expect(languages.contains("en"))
        #expect(languages.contains("es"))
        #expect(stream.hasGrabbableAudio)
    }
}
