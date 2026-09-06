import Foundation
import Testing
import DownloadModels
@testable import DownloadEngine

@Suite("Media intake robustness")
struct MediaIntakeRobustnessTests {
    @Test("Extractor retains parent adaptive manifests and inherited request context")
    func parentManifestAndHeaders() throws {
        let json = #"""
        {"title":"Episode","http_headers":{"User-Agent":"default","Referer":"https://player.example/"},"formats":[
          {"format_id":"hls-1080","url":"https://cdn.example/video/1080.m3u8",
           "manifest_url":"https://cdn.example/master.m3u8","protocol":"m3u8_native","ext":"mp4",
           "height":1080,"vcodec":"avc1","acodec":"none","http_headers":{"user-agent":"selected"}},
          {"format_id":"dash","url":"https://cdn.example/fragments/","manifest_url":"https://cdn.example/manifest.mpd",
           "protocol":"http_dash_segments","ext":"mp4","height":720,"vcodec":"avc1"}
        ]}
        """#
        let media = try ExtractedMedia.parse(json: Data(json.utf8))
        let format = try #require(media.preferredManifestFormat)
        #expect(format.resolvedManifestURL?.absoluteString == "https://cdn.example/master.m3u8")
        #expect(format.httpHeaders["Referer"] == "https://player.example/")
        #expect(format.httpHeaders["user-agent"] == "selected")
        #expect(format.httpHeaders["User-Agent"] == nil)
        #expect(media.formats.last?.resolvedManifestURL?.pathExtension == "mpd")
        #expect(media.directFormats.isEmpty)
    }

    @Test("Unsupported schemes, explicit DRM and manifest extensions never become direct files")
    func filtersUnsafeFormats() throws {
        let json = #"""
        {"formats":[
          {"format_id":"relative","url":"movie.mp4","ext":"mp4"},
          {"format_id":"local","url":"file:///private/movie.mp4","ext":"mp4"},
          {"format_id":"drm","url":"https://cdn.example/encrypted.mp4","ext":"mp4","has_drm":true},
          {"format_id":"playlist","url":"https://cdn.example/master.m3u8","ext":"mp4"},
          {"format_id":"clear","url":"https://cdn.example/movie.mp4","ext":"mp4"}
        ]}
        """#
        let media = try ExtractedMedia.parse(json: Data(json.utf8))
        #expect(media.formats.count == 3)
        #expect(media.directFormats.map(\.formatID) == ["clear"])
        #expect(media.preferredManifestFormat?.formatID == "playlist")
    }

    @Test("Codec-omitted audio pages produce a downloadable audio plan")
    func supportsAudioPage() throws {
        let json = #"""
        {"title":"Song","formats":[
          {"format_id":"low","url":"https://cdn.example/song-low.mp3","ext":"mp3","abr":64},
          {"format_id":"high","url":"https://cdn.example/song.mp3","ext":"mp3","abr":192}
        ]}
        """#
        let media = try ExtractedMedia.parse(json: Data(json.utf8))
        let stream = try #require(media.toMediaStream(pageURL: URL(string: "https://band.example/track/song")!))
        #expect(stream.hasGrabbableAudio)
        #expect(stream.bestVariant?.isAudioOnly == true)
        #expect(stream.bestVariant?.id == "high")
        #expect(stream.bestPlan?.segments.first?.url.lastPathComponent == "song.mp3")
        #expect(stream.bestPlan?.hasSeparateAudio == false)
    }

    @Test("Invalid numeric metadata cannot crash quality ranking")
    func invalidNumbers() throws {
        for bitrate in ["NaN", "inf", "1e200", "-20"] {
            let object: [String: Any] = ["formats": [
                ["url": "https://cdn.example/video.mp4", "ext": "mp4", "tbr": bitrate,
                 "width": Int.max, "height": Int.max]
            ]]
            let media = try ExtractedMedia.parse(json: JSONSerialization.data(withJSONObject: object))
            let stream = try #require(media.toMediaStream(pageURL: URL(string: "https://site.example/watch")!))
            #expect(stream.bestVariant?.resolution == nil)
            #expect((stream.bestVariant?.bandwidth ?? -1) >= 0)
        }
    }

    @Test("A higher silent tier must not displace a complete direct video")
    func completeVideoWinsOverUnpairedTier() throws {
        let media = ExtractedMedia(title: "Clip", formats: [
            ExtractedFormat(formatID: "complete", url: URL(string: "https://cdn.example/360.mp4")!,
                            ext: "mp4", vcodec: "avc1", acodec: "mp4a", width: 640, height: 360),
            ExtractedFormat(formatID: "silent", url: URL(string: "https://cdn.example/1080.mp4")!,
                            ext: "mp4", vcodec: "avc1", acodec: "none", width: 1920, height: 1080)
        ])
        let stream = try #require(media.toMediaStream(pageURL: URL(string: "https://site.example/watch")!))
        #expect(stream.bestVariant?.id == "complete")
    }

    @Test("Collapsing audio containers by language keeps video rendition groups resolvable")
    func languageGroupsSurviveContainerSelection() throws {
        let media = ExtractedMedia(title: "Dubbed", formats: [
            ExtractedFormat(formatID: "video", url: URL(string: "https://cdn.example/video.mp4")!,
                            ext: "mp4", vcodec: "avc1", width: 1920, height: 1080),
            ExtractedFormat(formatID: "en-aac", url: URL(string: "https://cdn.example/en.m4a")!,
                            ext: "m4a", acodec: "mp4a", abr: 128, language: "en"),
            ExtractedFormat(formatID: "en-opus", url: URL(string: "https://cdn.example/en.webm")!,
                            ext: "webm", acodec: "opus", abr: 256, language: "en"),
            ExtractedFormat(formatID: "es-opus", url: URL(string: "https://cdn.example/es.webm")!,
                            ext: "webm", acodec: "opus", abr: 128, language: "es")
        ])
        let stream = try #require(media.toMediaStream(pageURL: URL(string: "https://site.example/watch")!))
        let video = try #require(stream.bestVariant)
        let audio = try #require(stream.audioTracks.first { $0.groupID == video.audioGroupID })
        #expect(audio.id == "en-opus")
        #expect(stream.defaultAudioTrack?.language == "en")
    }

    @Test("DASH manifest fallback retains separate audio while direct progressive video keeps its own")
    func manifestFallbackRetainsAudio() throws {
        let mpd = """
        <MPD mediaPresentationDuration="PT6S"><Period>
          <AdaptationSet contentType="video" mimeType="video/mp4">
            <Representation id="v" bandwidth="1000000" width="1280" height="720">
              <SegmentTemplate media="video-$Number$.m4s" initialization="video-init.mp4" duration="6"/>
            </Representation>
          </AdaptationSet>
          <AdaptationSet contentType="audio" mimeType="audio/mp4" lang="en">
            <Representation id="a" bandwidth="128000">
              <SegmentTemplate media="audio-$Number$.m4s" initialization="audio-init.mp4" duration="6"/>
            </Representation>
          </AdaptationSet>
        </Period></MPD>
        """
        let manifest = try DASHParser.parse(Data(mpd.utf8), baseURL: URL(string: "https://cdn.example/manifest.mpd")!)
        let variant = try #require(manifest.bestVariant)
        #expect(variant.videoTrackPresent == nil)
        let plan = manifest.plan(for: variant, audio: manifest.audioTrack(for: variant))
        #expect(plan.hasSeparateAudio)
        #expect(plan.audioSegments?.first?.url.lastPathComponent == "audio-1.m4s")

        let progressive = MediaVariant(id: "direct", bandwidth: 1000000, resolution: variant.resolution,
                                       segments: [MediaSegment(id: 0, url: URL(string: "https://cdn.example/direct.mp4")!, duration: 0)],
                                       videoTrackPresent: true)
        #expect(manifest.audioTrack(for: progressive) == nil)
    }

    @Test("Redirected master and child playlists resolve relative paths at their final URL")
    func redirectedManifestBases() async throws {
        let source = URL(string: "https://site.example/play?id=42")!
        let masterURL = URL(string: "https://cdn.example/episode/master.m3u8")!
        let childURL = URL(string: "https://cdn.example/episode/video.m3u8")!
        let childFinal = URL(string: "https://edge.example/signed/playlist.m3u8")!
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000,RESOLUTION=1280x720\nvideo.m3u8"
        let child = "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:6,\nsegment.m4s\n#EXT-X-ENDLIST"
        let client = MockHTTPClient()
        client.setResource(.init(data: Data(master.utf8), finalURL: masterURL), for: source)
        client.setResource(.init(data: Data(child.utf8), finalURL: childFinal), for: childURL)
        let resolver = MediaResolver(httpClient: client)
        let stream = try await resolver.fetchManifest(url: source)
        #expect(stream.sourceURL == masterURL)
        let plan = try await resolver.resolvePlan(url: source)
        #expect(plan.segments.first?.url.absoluteString == "https://edge.example/signed/segment.m4s")
        #expect(plan.initSegment?.url.absoluteString == "https://edge.example/signed/init.mp4")
    }

    @Test("Separate audio failure must not silently publish a silent video")
    func missingAudioFailsPreparation() async throws {
        let source = URL(string: "https://cdn.example/master.m3u8")!
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",DEFAULT=YES,URI="missing.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=1000,RESOLUTION=1280x720,AUDIO="audio"
        video.m3u8
        """
        let child = "#EXTM3U\n#EXTINF:6,\nvideo.ts\n#EXT-X-ENDLIST"
        let client = MockHTTPClient()
        client.setResource(.init(data: Data(master.utf8)), for: source)
        client.setResource(.init(data: Data(child.utf8)), for: URL(string: "https://cdn.example/video.m3u8")!)
        await #expect(throws: (any Error).self) {
            _ = try await MediaResolver(httpClient: client).resolvePlan(url: source)
        }
    }
}
