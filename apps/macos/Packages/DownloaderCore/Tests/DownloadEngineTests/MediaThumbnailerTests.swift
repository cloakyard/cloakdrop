import Foundation
import ImageIO
import Testing
@testable import DownloadEngine

@Suite("Media thumbnailer (poster-frame JPEG)")
struct MediaThumbnailerTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cloakdrop-thumb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Generates a decodable JPEG bounded by the requested max dimension")
    func generatesBoundedJPEG() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("clip.mp4")
        try await MediaFixtures.writeVideoMP4(to: video)

        let data = try await MediaThumbnailer.generateJPEG(for: video, maxDimension: 160)
        #expect(!data.isEmpty)

        // It must be a real JPEG that decodes to an image no larger than the requested bound.
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let type = CGImageSourceGetType(source)
        #expect((type as String?) == "public.jpeg")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width > 0 && image.height > 0)
        #expect(image.width <= 160 && image.height <= 160)   // source is 320×240 → scaled down
    }

    @Test("An audio-only file has no video frame to sample, so it reports noVideoTrack")
    func rejectsAudioOnly() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("sound.m4a")
        try MediaFixtures.writeAudioM4A(to: audio)

        await #expect(throws: MediaThumbnailer.ThumbnailError.noVideoTrack) {
            _ = try await MediaThumbnailer.generateJPEG(for: audio)
        }
    }
}
