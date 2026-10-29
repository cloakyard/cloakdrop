import Foundation
import Testing
import DownloadModels
@testable import DownloadEngine

@Suite("Audio identity across extracted manifests")
struct AudioIdentityTests {
    private let url = URL(string: "https://cdn.example/playlist.m3u8")!

    @Test("An unlabelled audio site's HLS retains audio-only identity and its persisted output choice")
    func audioManifestIdentity() throws {
        let extracted = try ExtractedMedia.parse(json: Data(#"{"formats":[{"url":"https://cdn.example/playlist.m3u8","protocol":"m3u8_native","vcodec":"none","acodec":"mp4a.40.2","ext":"m4a"}]}"#.utf8))
        let stream = MediaStream(sourceURL: url, format: .hls, variants: [
            MediaVariant(id: "main", bandwidth: 0, segments: [MediaSegment(id: 0, url: url, duration: 1)])
        ])
        let mapped = extracted.applyingAudioIdentity(to: stream)
        #expect(mapped.hasGrabbableAudio)
        #expect(mapped.bestVariant?.isAudioOnly == true)
        #expect(mapped.bestPlan?.outputFormat == .originalAudio)
        #expect(try JSONDecoder().decode(MediaPlan.self, from: JSONEncoder().encode(mapped.bestPlan!)) == mapped.bestPlan)
        #expect(FileCategory.classify(fileName: "sound.mka") == .audio)
    }

    @Test("Mixed or unknown page formats cannot relabel a stream as audio", arguments: ["avc1.640028", "unknown"])
    func videoMetadataIsNotAudio(codec: String) throws {
        let extracted = try ExtractedMedia.parse(json: Data("""
        {"formats":[{"url":"https://cdn.example/playlist.m3u8","protocol":"m3u8_native","vcodec":"\(codec)","acodec":"mp4a.40.2","ext":"mp4"}]}
        """.utf8))
        let stream = MediaStream(sourceURL: url, format: .hls, variants: [MediaVariant(id: "main", bandwidth: 0)])
        #expect(extracted.applyingAudioIdentity(to: stream) == stream)
    }

    @Test("HLS audio choices stay in their quality's group; DASH retains alternate languages")
    func audioGroups() {
        let variant = MediaVariant(id: "720p", bandwidth: 1, codecs: ["avc1.640028"], audioGroupID: "high")
        let low = MediaTrack(id: "low-en", kind: .audio, groupID: "low", language: "en", isDefault: true)
        let high = MediaTrack(id: "high-en", kind: .audio, groupID: "high", language: "en")
        var stream = MediaStream(sourceURL: url, format: .hls, variants: [variant], audioTracks: [low, high])
        #expect(stream.selectableAudioTracks(for: variant).map(\.id) == ["high-en"])
        #expect(stream.audioTrack(for: variant)?.id == "high-en")
        stream = MediaStream(sourceURL: url, format: .dash, variants: [variant], audioTracks: [low, high])
        #expect(stream.selectableAudioTracks(for: variant).count == 2)
    }
}
