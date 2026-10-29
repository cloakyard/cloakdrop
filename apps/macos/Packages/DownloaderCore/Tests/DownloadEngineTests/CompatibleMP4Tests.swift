import AVFoundation
import Foundation
import Testing
import DownloadModels
@testable import DownloadEngine

@Suite("Compatible MP4 selection and packaging")
struct CompatibleMP4Tests {
    private let page = URL(string: "https://www.youtube.com/watch?v=example")!

    private func media(audio: String = "mp4a.40.2", video: String = "avc1.640028") throws -> ExtractedMedia {
        try ExtractedMedia.parse(json: Data("""
        {"title":"Example", "formats":[
          {"format_id":"av1","url":"https://cdn.test/av1.mp4","ext":"mp4","vcodec":"av01.0.08M.08","acodec":"none","height":2160,"tbr":8000},
          {"format_id":"h264","url":"https://cdn.test/h264.mp4","ext":"mp4","vcodec":"\(video)","acodec":"none","height":1080,"tbr":3000},
          {"format_id":"aac","url":"https://cdn.test/aac.m4a","ext":"m4a","vcodec":"none","acodec":"\(audio)","language":"en","abr":128},
          {"format_id":"opus","url":"https://cdn.test/opus.webm","ext":"webm","vcodec":"none","acodec":"opus","language":"en","abr":256}
        ]}
        """.utf8))
    }

    @Test("HLS MP4 selection requires compatible codec evidence and its referenced audio group")
    func compatibleHLS() throws {
        let aac = MediaTrack(id: "aac", kind: .audio, groupID: "aac", playlistURL: page)
        let other = MediaTrack(id: "other", kind: .audio, groupID: "other", playlistURL: page)
        let variants = [
            MediaVariant(id: "muxed", bandwidth: 1, codecs: ["avc1.640028", "mp4a.40.2"]),
            MediaVariant(id: "paired", bandwidth: 2, codecs: ["avc1.640028", "mp4a.40.2"], audioGroupID: "aac"),
            MediaVariant(id: "missing", bandwidth: 3, codecs: ["avc1.640028", "mp4a.40.2"], audioGroupID: "missing"),
            MediaVariant(id: "hevc", bandwidth: 4, codecs: ["hvc1.1.6.L93", "mp4a.40.2"]),
            MediaVariant(id: "unknown", bandwidth: 5, resolution: MediaResolution(width: 640, height: 360)),
            MediaVariant(id: "he-aac", bandwidth: 6, codecs: ["avc1.640028", "mp4a.40.5"])
        ]
        let stream = MediaStream(sourceURL: page, format: .hls, variants: variants, audioTracks: [aac, other])
        let compatible = try #require(stream.compatibleMP4Stream)
        #expect(compatible.variants.map(\.id) == ["muxed", "paired"])
        #expect(compatible.audioTracks.map(\.id) == ["aac"])
        #expect(stream.variants.count == 6)
        #expect(MediaStream(sourceURL: page, format: .dash, variants: variants).compatibleMP4Stream == nil)
    }

    @Test("MP4 offers H.264 and AAC while Original retains AV1 and higher quality tiers")
    func compatibleSelectionAndLanguageTracks() throws {
        let extracted = try media()
        let original = try #require(extracted.toMediaStream(pageURL: page))
        #expect(original.bestVariant?.id == "av1")
        let mp4 = try #require(extracted.toMediaStream(pageURL: page, outputFormat: .compatibleMP4))
        #expect(mp4.variants.map(\.id) == ["h264"])
        #expect(mp4.audioTracks.map(\.id) == ["aac"])
        let variant = try #require(mp4.bestVariant)
        #expect(mp4.plan(for: variant, audio: mp4.audioTrack(for: variant)).audioSegments?.first?.url.lastPathComponent == "aac.m4a")
    }

    @Test("MP4 is unavailable when compatible audio or video is absent", arguments: [true, false])
    func missingCompatibleTrack(audioMissing: Bool) throws {
        let extracted = try media(audio: audioMissing ? "opus" : "mp4a.40.2", video: audioMissing ? "avc1.640028" : "unknown")
        #expect(extracted.toMediaStream(pageURL: page) != nil)
        #expect(extracted.toMediaStream(pageURL: page, outputFormat: .compatibleMP4) == nil)
    }

    @Test("Progressive H.264/AAC survives MP4 filtering without an extra audio track")
    func progressiveMP4() throws {
        let extracted = try ExtractedMedia.parse(json: Data(#"{"url":"https://cdn.test/video.mp4","ext":"mp4","vcodec":"avc1.42001E","acodec":"mp4a.40.2"}"#.utf8))
        let stream = try #require(extracted.toMediaStream(pageURL: page, outputFormat: .compatibleMP4))
        #expect(stream.variants.count == 1)
        #expect(stream.audioTracks.isEmpty)
    }

    @Test("Output choice survives Codable storage and older plans still decode")
    func persistedOutputChoice() throws {
        var plan = MediaPlan.pairedFiles(video: page, audio: page)
        let legacy = try JSONEncoder().encode(plan)
        #expect(try JSONDecoder().decode(MediaPlan.self, from: legacy).outputFormat == nil)
        for format in [MediaOutputFormat.compatibleMP4, .originalAudio] {
            plan.outputFormat = format
            #expect(try JSONDecoder().decode(MediaPlan.self, from: JSONEncoder().encode(plan)) == plan)
        }
    }

    @Test("MP4 rejects AV1 despite an MP4 extension, for both native and FFmpeg backends")
    func rejectsIncompatibleDownloadedTracks() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "av1-30fps", withExtension: "mp4", subdirectory: "Fixtures"))
        let backends: [any Remuxer] = [AVFoundationRemuxer(), FFmpegMuxer(executableURL: URL(fileURLWithPath: "/not/launched"))]
        for backend in backends {
            await #expect(throws: RemuxError.unsupported) {
                _ = try await backend.remux(sourcePath: fixture.path, outputFormat: .compatibleMP4)
            }
            await #expect(throws: RemuxError.unsupported) {
                _ = try await backend.mux(videoPath: fixture.path, audioPath: fixture.path, outputFormat: .compatibleMP4)
            }
        }
    }

    @Test("Fragmented H.264 bypasses Apple's reader for mux and remux")
    func fragmentedH264UsesFallback() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "h264-fragmented", withExtension: "mp4", subdirectory: "Fixtures"))
        #expect(try MP4Container.isFragmented(at: fixture.path))
        let native = AVFoundationRemuxer()
        await #expect(throws: RemuxError.unsupported) {
            _ = try await native.remux(sourcePath: fixture.path)
        }
        await #expect(throws: RemuxError.unsupported) {
            _ = try await native.mux(videoPath: fixture.path, audioPath: fixture.path)
        }
    }

    @Test("Box inspection bounds malformed sizes and handles extended box lengths")
    func boxSizeBounds() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let samples: [(Data, Bool)] = [
            (Data([0, 0, 0, 8] + Array("moof".utf8)), true),
            (Data([0, 0, 0, 1] + Array("moof".utf8) + [0, 0, 0, 0, 0, 0, 0, 16]), true),
            (Data([0, 0, 0, 0] + Array("moof".utf8)), true),
            (Data([0, 0, 0, 4] + Array("moof".utf8)), false),
            (Data([255, 255, 255, 255] + Array("moof".utf8)), false),
            (Data([0, 0, 0, 1] + Array("moof".utf8) + [255, 255, 255, 255, 255, 255, 255, 255]), false),
            (Data([0, 0, 0]), false)
        ]
        for (data, expected) in samples {
            try data.write(to: file)
            #expect(try MP4Container.isFragmented(at: file.path) == expected)
        }
    }

    @Test("A composite never lets an unaware backend ignore an explicit MP4 choice")
    func compositeRequiresExplicitSupport() async throws {
        let composite = CompositeRemuxer([PassthroughRemuxer()])
        await #expect(throws: RemuxError.unsupported) {
            _ = try await composite.remux(sourcePath: "video.mp4", outputFormat: .compatibleMP4)
        }
    }
}
