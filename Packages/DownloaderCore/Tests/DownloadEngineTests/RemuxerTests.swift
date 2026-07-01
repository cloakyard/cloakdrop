import Foundation
import AVFoundation
import Testing
@testable import DownloadModels
@testable import DownloadPersistence
@testable import DownloadEngine

/// Exercises the real `AVFoundationRemuxer` against genuine, synthesized media (no network, no
/// fixtures on disk): a tiny H.264 MP4 and an AAC `.m4a` are written with AVFoundation itself,
/// then remuxed and re-opened to prove the passthrough produced a clean, correctly-typed file.
@Suite("Remux (AVFoundation passthrough to a clean container)")
struct RemuxerTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cloakdrop-remux-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("A plain MP4 is repackaged into a clean, seekable .mp4 with its video track intact")
    func remuxesVideoToMP4() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("assembly.mp4")
        try await MediaFixtures.writeVideoMP4(to: source)

        let result = try await AVFoundationRemuxer().remux(sourcePath: source.path)

        #expect(result.fileExtension == "mp4")
        #expect(result.outputPath != source.path)                     // a fresh, repackaged file
        #expect(FileManager.default.fileExists(atPath: result.outputPath))
        let asset = AVURLAsset(url: URL(fileURLWithPath: result.outputPath))
        #expect(try await !asset.loadTracks(withMediaType: .video).isEmpty)
        #expect(try await asset.load(.duration).seconds > 0)
    }

    @Test("An audio-only source is repackaged into an .m4a (no video track)")
    func remuxesAudioToM4A() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("assembly.m4a")
        try MediaFixtures.writeAudioM4A(to: source)

        let result = try await AVFoundationRemuxer().remux(sourcePath: source.path)

        #expect(result.fileExtension == "m4a")
        let asset = AVURLAsset(url: URL(fileURLWithPath: result.outputPath))
        #expect(try await asset.loadTracks(withMediaType: .video).isEmpty)
        #expect(try await !asset.loadTracks(withMediaType: .audio).isEmpty)
    }

    @Test("A non-media file is rejected as unsupported so the caller keeps the raw concatenation")
    func rejectsNonMedia() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("garbage.mp4")
        try Data((0..<8192).map { UInt8($0 % 256) }).write(to: source)

        await #expect(throws: RemuxError.self) {
            _ = try await AVFoundationRemuxer().remux(sourcePath: source.path)
        }
    }

    @Test("A full media grab remuxes end-to-end into a clean, playable file")
    func grabRemuxesEndToEnd() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // One self-contained MP4 stands in for the single media segment.
        let segmentFile = dir.appendingPathComponent("src.mp4")
        try await MediaFixtures.writeVideoMP4(to: segmentFile)
        let segmentData = try Data(contentsOf: segmentFile)

        let segURL = URL(string: "https://cdn/x/seg0.mp4")!
        let mock = MockHTTPClient()
        mock.setResource(.init(data: segmentData), for: segURL)
        let plan = MediaPlan(format: .hls, segments: [MediaSegment(id: 0, url: segURL, duration: 1)])

        let store = try GRDBDownloadStore.inMemory()
        let manager = DownloadManager(
            store: store, httpClient: mock,
            networkMonitor: AlwaysReachableMonitor(), remuxer: AVFoundationRemuxer()
        )
        try await manager.start()
        let request = DownloadRequest(
            url: URL(string: "https://cdn/x/master.m3u8")!,
            suggestedFileName: "clip.mp4", destinationDirectoryPath: dir.path
        )
        let download = await manager.addMedia(request, plan: plan)

        let done = try await waitForCompletion(manager, download.id)
        #expect((done.fileName as NSString).pathExtension == "mp4")
        let asset = AVURLAsset(url: URL(fileURLWithPath: done.destinationFilePath))
        #expect(try await !asset.loadTracks(withMediaType: .video).isEmpty)     // a real, openable video
        #expect(!FileManager.default.fileExists(atPath: done.mediaPartDirectoryPath))  // parts cleaned up
    }

    // MARK: - Helpers

    private func waitForCompletion(_ manager: DownloadManager, _ id: UUID) async throws -> Download {
        let deadline = ContinuousClock().now + .seconds(20)
        while ContinuousClock().now < deadline {
            if let download = await manager.snapshot().downloads.first(where: { $0.id == id }),
               download.status == .completed {
                return download
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw RemuxTestError.timeout
    }
}

private enum RemuxTestError: Error { case timeout }
