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

@Suite("Media extraction — YtDlpExtractor over a mock process")
struct YtDlpExtractorTests {
    private let fakeBinary = URL(fileURLWithPath: "/usr/bin/true")
    private let page = URL(string: "https://www.youtube.com/watch?v=abc123")!

    @Test func buildsExpectedArgumentsAndParses() async throws {
        let runner = MockProcessRunner(json: sampleJSON)
        let extractor = YtDlpExtractor(executableURL: fakeBinary, runner: runner)
        let media = try await extractor.extract(pageURL: page, cookies: "SID=abc", userAgent: "UA/1")

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

    @Test func omitsCookieAndUAWhenNotProvided() async throws {
        let runner = MockProcessRunner(json: sampleJSON)
        let extractor = YtDlpExtractor(executableURL: fakeBinary, runner: runner)
        _ = try await extractor.extract(pageURL: page, cookies: nil, userAgent: nil)
        #expect(!runner.lastArguments.contains("--add-header"))
        #expect(!runner.lastArguments.contains("--user-agent"))
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
