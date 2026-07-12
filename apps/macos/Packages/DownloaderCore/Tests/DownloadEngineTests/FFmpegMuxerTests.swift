import Foundation
import Testing
@testable import DownloadEngine

/// Exercises the ffmpeg backend and the composite that wires it behind AVFoundation. The composite
/// tests use stub remuxers (no binary), so they always run; the end-to-end mux/remux tests run only
/// when a real `ffmpeg` is installed on the machine (they synthesize genuine media and shell out).
@Suite("FFmpeg backend & composite remuxer")
struct FFmpegMuxerTests {
    // MARK: - FFmpegMuxer (bundled-binary tier)

    @Test("With no runnable binary, mux reports .unsupported so a composite can fall through")
    func missingBinaryIsUnsupportedForMux() async throws {
        let muxer = FFmpegMuxer(executableURL: URL(fileURLWithPath: "/does/not/exist/ffmpeg"))
        await #expect(throws: RemuxError.unsupported) {
            _ = try await muxer.mux(videoPath: "/tmp/v.mp4", audioPath: "/tmp/a.m4a")
        }
    }

    @Test("With no runnable binary, remux reports .unsupported too")
    func missingBinaryIsUnsupportedForRemux() async throws {
        let muxer = FFmpegMuxer(executableURL: URL(fileURLWithPath: "/does/not/exist/ffmpeg"))
        await #expect(throws: RemuxError.unsupported) {
            _ = try await muxer.remux(sourcePath: "/tmp/x.mp4")
        }
    }

    @Test("locate returns nil when the bundle carries no ffmpeg")
    func locateReturnsNilWithoutBundledBinary() {
        // The test runner's main bundle has no bundled `ffmpeg` resource.
        #expect(FFmpegMuxer.locate(in: .main) == nil)
    }

    @Test("Muxes a real H.264 video and AAC audio into one .mkv carrying both streams",
          .enabled(if: Tools.ffmpeg != nil))
    func muxesRealVideoAndAudioIntoMatroska() async throws {
        let ffmpeg = try #require(Tools.ffmpeg)
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("v.mp4")
        let audio = dir.appendingPathComponent("a.m4a")
        try await MediaFixtures.writeVideoMP4(to: video)   // H.264, video-only
        try MediaFixtures.writeAudioM4A(to: audio)          // AAC, audio-only

        let result = try await FFmpegMuxer(executableURL: ffmpeg).mux(videoPath: video.path, audioPath: audio.path)

        #expect(result.fileExtension == "mkv")
        #expect(FileManager.default.fileExists(atPath: result.outputPath))
        try assertHasVideoAndAudio(result.outputPath)
    }

    @Test("Remuxes a real file into a clean .mkv keeping its video stream",
          .enabled(if: Tools.ffmpeg != nil))
    func remuxesRealFileIntoMatroska() async throws {
        let ffmpeg = try #require(Tools.ffmpeg)
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("src.mp4")
        try await MediaFixtures.writeVideoMP4(to: source)

        let result = try await FFmpegMuxer(executableURL: ffmpeg).remux(sourcePath: source.path)

        #expect(result.fileExtension == "mkv")
        #expect(FileManager.default.fileExists(atPath: result.outputPath))
        if let types = try streamTypes(of: result.outputPath) {
            #expect(types.contains("video"))
        }
    }

    // MARK: - CompositeRemuxer (ordered fallback)

    @Test("mux uses the first backend that succeeds and never calls later ones")
    func compositeUsesFirstSuccess() async throws {
        let log = CallLog()
        let composite = CompositeRemuxer([
            StubRemuxer(name: "a", outcome: .success("mp4"), log: log),
            StubRemuxer(name: "b", outcome: .success("mkv"), log: log)
        ])
        let result = try await composite.mux(videoPath: "/x/v", audioPath: "/x/a")
        #expect(result.fileExtension == "mp4")
        #expect(await log.names == ["a"])
    }

    @Test("mux falls through an .unsupported backend to the next one")
    func compositeFallsThroughUnsupported() async throws {
        let log = CallLog()
        let composite = CompositeRemuxer([
            StubRemuxer(name: "a", outcome: .unsupported, log: log),
            StubRemuxer(name: "b", outcome: .success("mkv"), log: log)
        ])
        let result = try await composite.mux(videoPath: "/x/v", audioPath: "/x/a")
        #expect(result.fileExtension == "mkv")
        #expect(await log.names == ["a", "b"])   // tried in order
    }

    @Test("mux also falls through a .failed backend to a working one")
    func compositeFallsThroughFailed() async throws {
        let log = CallLog()
        let composite = CompositeRemuxer([
            StubRemuxer(name: "a", outcome: .failed, log: log),
            StubRemuxer(name: "b", outcome: .success("mkv"), log: log)
        ])
        #expect(try await composite.mux(videoPath: "/x/v", audioPath: "/x/a").fileExtension == "mkv")
        #expect(await log.names == ["a", "b"])
    }

    @Test("mux throws when every backend fails")
    func compositeThrowsWhenAllFail() async throws {
        let log = CallLog()
        let composite = CompositeRemuxer([
            StubRemuxer(name: "a", outcome: .unsupported, log: log),
            StubRemuxer(name: "b", outcome: .failed, log: log)
        ])
        await #expect(throws: RemuxError.self) {
            _ = try await composite.mux(videoPath: "/x/v", audioPath: "/x/a")
        }
        #expect(await log.names == ["a", "b"])
    }

    @Test("an empty composite is unsupported")
    func emptyCompositeIsUnsupported() async throws {
        await #expect(throws: RemuxError.unsupported) {
            _ = try await CompositeRemuxer([]).remux(sourcePath: "/x/y")
        }
    }

    @Test("remux falls through to the next backend as well as mux")
    func compositeRemuxFallsThrough() async throws {
        let log = CallLog()
        let composite = CompositeRemuxer([
            StubRemuxer(name: "a", outcome: .unsupported, log: log),
            StubRemuxer(name: "b", outcome: .success("m4a"), log: log)
        ])
        #expect(try await composite.remux(sourcePath: "/x/y").fileExtension == "m4a")
        #expect(await log.names == ["a", "b"])
    }

    // MARK: - Helpers

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cloakdrop-ffmpeg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Assert (via ffprobe, since AVFoundation can't open Matroska) that a file has both a video and
    /// an audio stream. Falls back to a non-empty-file check when ffprobe isn't available.
    private func assertHasVideoAndAudio(_ path: String) throws {
        if let types = try streamTypes(of: path) {
            #expect(types.contains("video"))
            #expect(types.contains("audio"))
        } else {
            let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            #expect(size > 0)
        }
    }

    /// The `codec_type` of each stream in `path` via ffprobe, or nil when ffprobe isn't installed.
    private func streamTypes(of path: String) throws -> [String]? {
        guard let ffprobe = Tools.ffprobe else { return nil }
        let output = try Tools.runCapturingStdout(
            ffprobe, ["-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", path]
        )
        return output.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }
}

// MARK: - Tool discovery (real ffmpeg/ffprobe, when installed)

private enum Tools {
    static let ffmpeg = locate("ffmpeg")
    static let ffprobe = locate("ffprobe")

    private static func locate(_ name: String) -> URL? {
        for dir in ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"] {
            let path = dir + name
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// Run a tool and return its stdout (stderr silenced). Test-only; blocking is fine here.
    static func runCapturingStdout(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Stub remuxers for the composite tests

private enum Outcome: Sendable {
    case success(String)   // succeed with this fileExtension
    case unsupported
    case failed

    func result(path: String) throws -> RemuxResult {
        switch self {
        case .success(let ext): return RemuxResult(outputPath: path + ".\(ext)", fileExtension: ext)
        case .unsupported: throw RemuxError.unsupported
        case .failed: throw RemuxError.failed("boom")
        }
    }
}

private actor CallLog {
    private(set) var names: [String] = []
    func record(_ name: String) { names.append(name) }
}

private struct StubRemuxer: Remuxer {
    let name: String
    let outcome: Outcome
    let log: CallLog

    func remux(sourcePath: String) async throws -> RemuxResult {
        await log.record(name)
        return try outcome.result(path: sourcePath)
    }

    func mux(videoPath: String, audioPath: String) async throws -> RemuxResult {
        await log.record(name)
        return try outcome.result(path: videoPath)
    }
}
