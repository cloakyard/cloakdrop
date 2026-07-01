import Foundation
import Testing
@testable import DownloadModels

@Suite("Media plan & Download media progress")
struct MediaPlanTests {
    private func segment(_ id: Int, _ url: String, encryption: MediaEncryption = .none) -> MediaSegment {
        MediaSegment(id: id, url: URL(string: url)!, duration: 6, encryption: encryption)
    }

    @Test("plan(for:) and bestPlan pick the resolved, highest-bandwidth variant")
    func buildsPlan() {
        let low = MediaVariant(id: "0", bandwidth: 800_000, resolution: MediaResolution(width: 640, height: 360),
                               segments: [segment(0, "https://x/lo0.ts")])
        let high = MediaVariant(id: "1", bandwidth: 2_400_000, resolution: MediaResolution(width: 1920, height: 1080),
                                segments: [segment(0, "https://x/hi0.ts"), segment(1, "https://x/hi1.ts")])
        // An unresolved higher-bandwidth variant must be ignored (no segments to download).
        let unresolved = MediaVariant(id: "2", bandwidth: 9_000_000, playlistURL: URL(string: "https://x/huge.m3u8"))
        let stream = MediaStream(sourceURL: URL(string: "https://x/master.m3u8")!, format: .hls,
                                 variants: [low, high, unresolved])

        let plan = try! #require(stream.bestPlan)
        #expect(plan.bandwidth == 2_400_000)
        #expect(plan.resolution == MediaResolution(width: 1920, height: 1080))
        #expect(plan.totalSegments == 2)
        #expect(plan.duration == 12)
        #expect(plan.format == .hls)
    }

    @Test("A variant is classified video/audio by codecs, not just RESOLUTION")
    func variantVideoAudioClassification() {
        // The bipbop regression: a variant that omits RESOLUTION but declares a video codec must
        // read as video (it was mislabeled "Audio" when only resolution was checked).
        let videoNoRes = MediaVariant(id: "0", bandwidth: 1_927_833, codecs: ["mp4a.40.2", "avc1.4d401f"])
        #expect(videoNoRes.hasVideo)
        #expect(videoNoRes.isAudioOnly == false)

        // A codecs-only audio rendition (no video codec) is audio-only.
        let audioOnly = MediaVariant(id: "1", bandwidth: 41_457, codecs: ["mp4a.40.2"])
        #expect(audioOnly.hasVideo == false)
        #expect(audioOnly.isAudioOnly)

        // Resolution present is video regardless of codecs.
        let withRes = MediaVariant(id: "2", bandwidth: 800_000,
                                   resolution: MediaResolution(width: 640, height: 360))
        #expect(withRes.hasVideo)
        #expect(withRes.isAudioOnly == false)

        // Other video families (HEVC, AV1) are recognized.
        #expect(MediaVariant(id: "3", bandwidth: 1, codecs: ["hvc1.1.6.L93.B0"]).hasVideo)
        #expect(MediaVariant(id: "4", bandwidth: 1, codecs: ["av01.0.05M.08"]).hasVideo)

        // No codecs and no resolution: not audio-only (a bare variant stream reads as video).
        let unknown = MediaVariant(id: "5", bandwidth: 500_000)
        #expect(unknown.hasVideo == false)
        #expect(unknown.isAudioOnly == false)
    }

    @Test("hasUnsupportedEncryption and keyURLs reflect the segments")
    func encryptionSummary() {
        let key = URL(string: "https://k/e.bin")!
        let aes = MediaEncryption(method: .aes128, keyURL: key)
        let plan = MediaPlan(format: .hls, segments: [
            segment(0, "https://x/0.ts", encryption: aes),
            segment(1, "https://x/1.ts", encryption: aes)
        ])
        #expect(plan.hasUnsupportedEncryption == false)
        #expect(plan.keyURLs == [key])

        let sample = MediaPlan(format: .hls, segments: [segment(0, "https://x/0.ts",
            encryption: MediaEncryption(method: .sampleAES, keyURL: URL(string: "skd://x")))])
        #expect(sample.hasUnsupportedEncryption)
        #expect(sample.keyURLs.isEmpty) // only AES-128 keys are fetched
    }

    @Test("Download media progress is segment-count based and has its own part directory")
    func mediaDownloadProgress() {
        let plan = MediaPlan(format: .hls, segments: (0..<4).map { segment($0, "https://x/\($0).ts") })
        var download = Download(url: URL(string: "https://x/master.m3u8")!, fileName: "video.mp4",
                                destinationDirectoryPath: "/tmp/dl", mediaPlan: plan)
        #expect(download.isMedia)
        #expect(download.mediaPartDirectoryPath == "/tmp/dl/video.mp4.cloakparts")
        #expect(download.fractionCompleted == 0)
        #expect(download.allSegmentsComplete == false)

        download.mediaCompletedSegments = 2
        download.mediaDownloadedBytes = 5_000
        #expect(download.fractionCompleted == 0.5)   // 2/4, independent of unknown total bytes
        #expect(download.downloadedBytes == 5_000)

        download.mediaCompletedSegments = 4
        #expect(download.fractionCompleted == 1.0)
        #expect(download.allSegmentsComplete)
    }

    @Test("A non-media download keeps byte-based progress")
    func fileDownloadUnaffected() {
        var download = Download(url: URL(string: "https://x/f.zip")!, fileName: "f.zip",
                                destinationDirectoryPath: "/tmp", totalBytes: 1000,
                                segments: [DownloadSegment(id: 0, start: 0, end: 999, downloadedBytes: 250)])
        #expect(download.isMedia == false)
        #expect(download.downloadedBytes == 250)
        #expect(download.fractionCompleted == 0.25)
        download.segments[0].downloadedBytes = 1000
        #expect(download.allSegmentsComplete)
    }
}
