import Foundation
import Testing
@testable import DownloadEngine
@testable import DownloadModels
@testable import DownloadPersistence

/// Explicit, opt-in live media checks. Normal test runs never contact public sites.
/// Supply a JSON case list through CLOAKDROP_LIVE_MEDIA_CONFIG plus executable/output paths
/// documented in scripts/tests/README.md. All state lives in a disposable in-memory catalog.
@Suite("Live media smoke (opt-in)", .serialized)
struct LiveMediaSmokeTests {
    private struct MediaCase: Decodable {
        let name: String
        let url: URL
        let mode: String
        let expectedDuration: Double
        let maxHeight: Int?
        let expectVideo: Bool
        let expectAudio: Bool
        let expectedVideoPackets: Int?
        let expectedAudioPackets: Int?
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @Test("Selected pages resolve, download, package and decode completely",
          .enabled(if: ProcessInfo.processInfo.environment["CLOAKDROP_LIVE_MEDIA_CONFIG"] != nil))
    func selectedPages() async throws {
        let env = ProcessInfo.processInfo.environment
        let config = try #require(env["CLOAKDROP_LIVE_MEDIA_CONFIG"])
        let output = URL(fileURLWithPath: try #require(env["CLOAKDROP_LIVE_MEDIA_OUTPUT"]))
        let extractor = YtDlpExtractor(executableURL: URL(fileURLWithPath: try #require(env["YTDLP_PATH"])))
        let muxer = FFmpegMuxer(executableURL: URL(fileURLWithPath: try #require(env["FFMPEG_PATH"])))
        let probe = URL(fileURLWithPath: try #require(env["FFPROBE_PATH"]))
        let decoder = URL(fileURLWithPath: try #require(env["MEDIA_DECODER_PATH"]))
        let cases = try JSONDecoder().decode([MediaCase].self, from: Data(contentsOf: URL(fileURLWithPath: config)))
        try #require(!cases.isEmpty)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for item in cases {
            // Case labels are local filenames, never URLs or extractor-supplied titles.
            guard !item.name.isEmpty, item.name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                throw Failure(description: "Invalid case filename")
            }
            print("[live-media] START \(item.name)")
            do {
                try await run(item, extractor: extractor, muxer: muxer, probe: probe, decoder: decoder, output: output)
            } catch {
                // Keep CDN tokens/cookies out of committed evidence. Detailed failures stay in this
                // caller-selected local directory; the shared console identifies only the case.
                try String(describing: error).write(to: output.appendingPathComponent(item.name + ".failure.txt"),
                                                   atomically: true, encoding: .utf8)
                Issue.record("Live media case \(item.name) failed; inspect its private failure artifact")
            }
        }
    }

    private func run(
        _ item: MediaCase, extractor: YtDlpExtractor, muxer: FFmpegMuxer,
        probe: URL, decoder: URL, output: URL
    ) async throws {
        let directory = output.appendingPathComponent(item.name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let client = URLSessionHTTPClient()
        defer { client.invalidate() }
        let manager = DownloadManager(store: try GRDBDownloadStore.inMemory(), httpClient: client,
                                      networkMonitor: AlwaysReachableMonitor(),
                                      remuxer: CompositeRemuxer([AVFoundationRemuxer(), muxer]))
        try await manager.start()
        var settings = await manager.currentSettings()
        settings.defaultSegmentCount = 4
        settings.maxSegmentCount = 4
        settings.maxRetryAttempts = 2
        settings.retryBaseDelaySeconds = 0.25
        settings.retryMaxDelaySeconds = 1
        settings.verifyChecksumsAutomatically = false
        settings.autoDiscoverChecksums = false
        settings.assessSignatures = false
        settings.autoCategorize = false
        settings.applyQuarantine = false
        settings.autoExtractArchives = false
        settings.generateProvenanceReceipts = false
        await manager.updateSettings(settings)

        let media = try await extractor.extract(pageURL: item.url, cookies: nil, userAgent: nil)
        guard !media.isLive else { throw Failure(description: "Live broadcasts are outside this bounded VOD check") }
        let resolved = try await resolve(media, item: item, manager: manager)
        let added = await manager.addMedia(DownloadRequest(
            url: resolved.url, suggestedFileName: item.name + ".mp4", destinationDirectoryPath: directory.path,
            requestHeaders: resolved.headers
        ), plan: resolved.plan)
        let finished: Download
        do {
            finished = try await waitFor(manager, id: added.id)
        } catch {
            await manager.cancel(id: added.id)
            throw error
        }
        let path = finished.destinationFilePath
        let runner = SystemProcessRunner()
        let result = try await runner.run(executable: probe, arguments: [
            "-v", "error", "-count_frames", "-count_packets", "-show_entries",
            "stream=codec_name,codec_type,duration,avg_frame_rate,nb_read_frames,nb_read_packets:format=format_name,duration,size",
            "-of", "json", path
        ], timeout: .seconds(60))
        guard result.exitCode == 0 else { throw Failure(description: "FFprobe failed: \(result.stderrTail)") }
        try result.stdout.write(to: output.appendingPathComponent(item.name + ".probe.json"))
        try validate(result.stdout, item: item, extension: URL(fileURLWithPath: path).pathExtension)
        let decoded = try await runner.run(executable: decoder, arguments: [
            "-nostdin", "-v", "error", "-xerror", "-i", path, "-map", "0:v?", "-map", "0:a?", "-f", "null", "-"
        ], timeout: .seconds(90))
        guard decoded.exitCode == 0 else { throw Failure(description: "Full decode failed: \(decoded.stderrTail)") }
        try #require(!FileManager.default.fileExists(atPath: finished.mediaPartDirectoryPath))
        print("[live-media] PASS \(item.name) mode=\(item.mode) output=\(URL(fileURLWithPath: path).lastPathComponent) fullDecode=true")
    }

    private struct Resolved {
        let url: URL
        let headers: [String: String]
        let plan: MediaPlan
    }

    private func resolve(_ media: ExtractedMedia, item: MediaCase, manager: DownloadManager) async throws -> Resolved {
        let format: MediaOutputFormat = item.mode == "mp4" ? .compatibleMP4 : .original
        var sourceURL = item.url
        var headers = media.downloadHeaders
        let stream: MediaStream
        if let direct = media.toMediaStream(pageURL: item.url, outputFormat: format) {
            stream = direct
        } else {
            guard let manifest = media.preferredManifestFormat,
                  let url = manifest.resolvedManifestURL else { throw Failure(description: "Requested format has no usable stream") }
            sourceURL = url
            headers = manifest.httpHeaders
            let manifestStream = media.applyingAudioIdentity(to: try await manager.resolveMediaStream(url: url, headers: headers))
            if format == .compatibleMP4 {
                stream = try #require(manifestStream.compatibleMP4Stream)
            } else {
                stream = manifestStream
            }
        }
        var plan: MediaPlan
        if item.mode == "audio", !stream.standaloneAudioTracks.isEmpty {
            plan = try await manager.resolveAudioOnlyPlan(from: stream, trackID: nil, headers: headers)
        } else {
            let candidates = stream.variants.sorted(by: MediaVariant.higherQualityFirst)
            let variant = try #require(candidates.first { ($0.resolution?.qualityHeight ?? 0) <= (item.maxHeight ?? 720) }
                                      ?? candidates.last)
            if let direct = media.formats.first(where: { $0.formatID == variant.id && $0.isDirectFile }) {
                headers = direct.httpHeaders
            }
            plan = try await manager.resolveMediaPlan(from: stream, variantID: variant.id, headers: headers)
        }
        if plan.outputFormat != .originalAudio { plan.outputFormat = format }
        return Resolved(url: sourceURL, headers: headers, plan: plan)
    }

    private func waitFor(_ manager: DownloadManager, id: UUID) async throws -> Download {
        let deadline = ContinuousClock.now + .seconds(180)
        while ContinuousClock.now < deadline {
            if let item = await manager.snapshot().downloads.first(where: { $0.id == id }) {
                if item.status == .completed { return item }
                if case .failed(let reason) = item.status { throw Failure(description: reason) }
                if item.status == .canceled { throw Failure(description: "Canceled") }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure(description: "Transfer exceeded 180 seconds")
    }

    private func validate(_ data: Data, item: MediaCase, extension ext: String) throws {
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let streams = try #require(root["streams"] as? [[String: Any]])
        let video = streams.filter { $0["codec_type"] as? String == "video" }
        let audio = streams.filter { $0["codec_type"] as? String == "audio" }
        try #require(!video.isEmpty == item.expectVideo)
        try #require(!audio.isEmpty == item.expectAudio)
        let format = try #require(root["format"] as? [String: Any])
        let duration = try #require((format["duration"] as? String).flatMap(Double.init))
        try #require(abs(duration - item.expectedDuration) < max(1, item.expectedDuration * 0.01))
        for stream in streams {
            if let seconds = (stream["duration"] as? String).flatMap(Double.init) {
                try #require(abs(seconds - item.expectedDuration) < max(1, item.expectedDuration * 0.01))
            }
            let packets = try #require((stream["nb_read_packets"] as? String).flatMap(Int.init))
            try #require(packets > 0)
            let expected = stream["codec_type"] as? String == "video" ? item.expectedVideoPackets : item.expectedAudioPackets
            if let expected { try #require(packets == expected) }
        }
        if item.mode == "mp4" {
            try #require(ext == "mp4")
            try #require(video.allSatisfy { $0["codec_name"] as? String == "h264" })
            try #require(audio.allSatisfy { $0["codec_name"] as? String == "aac" })
        }
        if !item.expectVideo {
            try #require(FileCategory.classify(fileName: "result.\(ext)") == .audio)
        }
    }
}
