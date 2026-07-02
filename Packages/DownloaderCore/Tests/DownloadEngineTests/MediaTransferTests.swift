import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadPersistence
@testable import DownloadEngine

@Suite("Media transfer (segment grab through the engine)")
struct MediaTransferTests {
    /// Deterministic, content-checkable segment payload.
    private func payload(_ seed: Int, _ count: Int = 4000) -> Data {
        Data((0..<count).map { UInt8(($0 + seed) % 251) })
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cloakdrop-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeManager(
        store: any DownloadStore,
        mock: MockHTTPClient,
        remuxer: any Remuxer = PassthroughRemuxer()
    ) async throws -> DownloadManager {
        let manager = DownloadManager(store: store, httpClient: mock, networkMonitor: AlwaysReachableMonitor(), remuxer: remuxer)
        try await manager.start()
        var settings = await manager.currentSettings()
        settings.retryBaseDelaySeconds = 0.01
        settings.retryMaxDelaySeconds = 0.05
        await manager.updateSettings(settings)
        return manager
    }

    private func waitFor(
        _ manager: DownloadManager,
        _ id: UUID,
        timeout: Duration = .seconds(15),
        where predicate: @Sendable (Download) -> Bool
    ) async throws -> Download {
        let deadline = ContinuousClock().now + timeout
        while ContinuousClock().now < deadline {
            if let download = await manager.snapshot().downloads.first(where: { $0.id == id }), predicate(download) {
                return download
            }
            try await Task.sleep(for: .milliseconds(15))
        }
        throw MediaTimeout()
    }

    @Test("A cleartext grab downloads every segment, concatenates init + segments, and cleans up")
    func grabCompletes() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let initData = Data("fMP4-INIT".utf8)
        let segs = (0..<5).map { payload($0) }
        let initURL = URL(string: "https://cdn/x/init.mp4")!
        let segURLs = (0..<5).map { URL(string: "https://cdn/x/seg\($0).m4s")! }

        let mock = MockHTTPClient()
        mock.setResource(.init(data: initData), for: initURL)
        for (index, url) in segURLs.enumerated() { mock.setResource(.init(data: segs[index]), for: url) }

        let plan = MediaPlan(
            format: .hls,
            initSegment: MediaInitSegment(url: initURL),
            segments: segURLs.enumerated().map { MediaSegment(id: $0.offset, url: $0.element, duration: 6) },
            resolution: MediaResolution(width: 1280, height: 720),
            bandwidth: 1_500_000
        )

        let store = try GRDBDownloadStore.inMemory()
        let manager = try await makeManager(store: store, mock: mock)
        let request = DownloadRequest(url: URL(string: "https://cdn/x/master.m3u8")!, suggestedFileName: "clip.mp4", destinationDirectoryPath: dir.path)
        let download = await manager.addMedia(request, plan: plan)
        let done = try await waitFor(manager, download.id) { $0.status == .completed }

        let expected = initData + segs.reduce(Data(), +)
        #expect(try Data(contentsOf: URL(fileURLWithPath: done.destinationFilePath)) == expected)
        #expect(done.fractionCompleted == 1.0)
        #expect(done.mediaCompletedSegments == 5)
        #expect(!FileManager.default.fileExists(atPath: done.mediaPartDirectoryPath)) // part dir removed
        #expect(!FileManager.default.fileExists(atPath: done.partFilePath))           // assembly file moved
    }

    @Test("An AES-128 grab fetches the key and decrypts each segment to the original bytes")
    func grabDecryptsAES128() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let key = Data((0..<16).map { UInt8($0) })
        let iv = Data((16..<32).map { UInt8($0) })
        let keyURL = URL(string: "https://cdn/keys/k.bin")!
        let plainSegs = (0..<3).map { payload($0) }
        let segURLs = (0..<3).map { URL(string: "https://cdn/x/enc\($0).ts")! }

        let mock = MockHTTPClient()
        mock.setResource(.init(data: key), for: keyURL)
        for (index, url) in segURLs.enumerated() {
            let cipher = try AES128.encryptCBC(plainSegs[index], key: key, iv: iv)
            mock.setResource(.init(data: cipher), for: url)
        }

        let encryption = MediaEncryption(method: .aes128, keyURL: keyURL, iv: iv)
        let plan = MediaPlan(format: .hls, segments: segURLs.enumerated().map {
            MediaSegment(id: $0.offset, url: $0.element, duration: 6, encryption: encryption)
        })

        let store = try GRDBDownloadStore.inMemory()
        let manager = try await makeManager(store: store, mock: mock)
        let request = DownloadRequest(url: URL(string: "https://cdn/x/enc.m3u8")!, suggestedFileName: "enc.mp4", destinationDirectoryPath: dir.path)
        let download = await manager.addMedia(request, plan: plan)
        let done = try await waitFor(manager, download.id) { $0.status == .completed }

        // The assembled file must be the *decrypted* concatenation, not the ciphertext.
        #expect(try Data(contentsOf: URL(fileURLWithPath: done.destinationFilePath)) == plainSegs.reduce(Data(), +))
        // With no remux (PassthroughRemuxer), the name honestly reflects the raw container: the
        // `.mp4` we asked for is corrected to `.ts` since the concatenation is an MPEG-TS stream.
        #expect((done.fileName as NSString).pathExtension == "ts")
        #expect(done.category == .video)
    }

    @Test("Without a remux, the file keeps the segments' own container extension (raw .aac stays .aac, not .mp4)")
    func grabHonorsSegmentContainer() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let segs = (0..<3).map { payload($0) }
        let segURLs = (0..<3).map { URL(string: "https://cdn/a/part\($0).aac")! }
        let mock = MockHTTPClient()
        for (index, url) in segURLs.enumerated() { mock.setResource(.init(data: segs[index]), for: url) }
        let plan = MediaPlan(format: .hls, segments: segURLs.enumerated().map {
            MediaSegment(id: $0.offset, url: $0.element, duration: 6)
        })

        let store = try GRDBDownloadStore.inMemory()
        let manager = try await makeManager(store: store, mock: mock)   // PassthroughRemuxer — no remux
        let request = DownloadRequest(url: URL(string: "https://cdn/a/audio.m3u8")!, suggestedFileName: "audio.mp4", destinationDirectoryPath: dir.path)
        let download = await manager.addMedia(request, plan: plan)
        let done = try await waitFor(manager, download.id) { $0.status == .completed }

        // Raw `.aac` segments must assemble into an honestly-named `.aac` file, not a mislabelled
        // `.mp4` — the mislabelling broke AVFoundation's sniffing for real audio-only renditions.
        #expect((done.fileName as NSString).pathExtension == "aac")
        #expect(try Data(contentsOf: URL(fileURLWithPath: done.destinationFilePath)) == segs.reduce(Data(), +))
    }

    @Test("A media grab resumes across a simulated relaunch, refetching only the unfinished segments")
    func grabResumesAcrossRelaunch() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("state.sqlite").path

        let segs = (0..<8).map { payload($0, 6000) }
        let segURLs = (0..<8).map { URL(string: "https://cdn/x/s\($0).ts")! }
        let master = URL(string: "https://cdn/x/master.m3u8")!
        func makeResources(_ mock: MockHTTPClient) {
            for (index, url) in segURLs.enumerated() { mock.setResource(.init(data: segs[index]), for: url) }
        }
        let plan = MediaPlan(format: .hls, segments: segURLs.enumerated().map {
            MediaSegment(id: $0.offset, url: $0.element, duration: 4)
        })
        let request = DownloadRequest(url: master, suggestedFileName: "resume.mp4", destinationDirectoryPath: dir.path)

        // First launch: start the grab, slow it, then pause with a genuine partial (some segments done).
        let store1 = try GRDBDownloadStore(path: dbPath)
        let mock1 = MockHTTPClient()
        mock1.chunkSize = 1024
        mock1.perChunkDelay = .milliseconds(8)
        makeResources(mock1)
        let manager1 = DownloadManager(store: store1, httpClient: mock1, networkMonitor: AlwaysReachableMonitor(), remuxer: PassthroughRemuxer())
        try await manager1.start()
        var settings = await manager1.currentSettings()
        settings.defaultSegmentCount = 1   // one segment at a time, so the grab can't finish before we pause
        await manager1.updateSettings(settings)

        let added = await manager1.addMedia(request, plan: plan)
        try await awaitFirstSegment(manager1, added.id)   // deterministic: pause only after a segment lands
        await manager1.pause(id: added.id)
        let paused = try await waitFor(manager1, added.id) { $0.status == .paused }
        #expect(paused.mediaCompletedSegments > 0)                 // some finished
        #expect(paused.mediaCompletedSegments < 8)                 // but not all — a real partial

        // Second launch: brand-new manager, same store + part directory. Resume to completion.
        let store2 = try GRDBDownloadStore(path: dbPath)
        let mock2 = MockHTTPClient()
        makeResources(mock2)
        let manager2 = DownloadManager(store: store2, httpClient: mock2, networkMonitor: AlwaysReachableMonitor(), remuxer: PassthroughRemuxer())
        try await manager2.start()
        await manager2.resume(id: added.id)
        let done = try await waitFor(manager2, added.id) { $0.status == .completed }

        #expect(try Data(contentsOf: URL(fileURLWithPath: done.destinationFilePath)) == segs.reduce(Data(), +))
        // Resume must have skipped the already-downloaded segments, not refetched all eight.
        #expect(mock2.streamCount < 8)
    }

    @Test("deriveMediaFileName picks a title stem and a container from the plan")
    func mediaFileName() {
        let variantURL = URL(string: "https://cdn.example.com/v/bipbop_16x9_variant.m3u8")!
        let tsPlan = MediaPlan(format: .hls, segments: [
            MediaSegment(id: 0, url: URL(string: "https://cdn.example.com/v/seg0.ts")!, duration: 6)
        ])
        // A TS stream (no init segment, .ts parts) keeps a .ts container.
        #expect(DownloadManager.deriveMediaFileName(from: variantURL, plan: tsPlan) == "bipbop_16x9_variant.ts")

        // An fMP4 stream (init segment present) becomes .mp4.
        let fmp4Plan = MediaPlan(
            format: .hls,
            initSegment: MediaInitSegment(url: URL(string: "https://cdn.example.com/v/init.mp4")!),
            segments: [MediaSegment(id: 0, url: URL(string: "https://cdn.example.com/v/seg0.m4s")!, duration: 6)]
        )
        #expect(DownloadManager.deriveMediaFileName(from: variantURL, plan: fmp4Plan) == "bipbop_16x9_variant.mp4")

        // A generic "master.m3u8" name falls back to the containing path segment.
        let genericURL = URL(string: "https://cdn.example.com/myvideo/master.m3u8")!
        #expect(DownloadManager.deriveMediaFileName(from: genericURL, plan: fmp4Plan) == "myvideo.mp4")
    }

    @Test("A drop mid-segment resumes from the bytes on disk with a ranged request, not from scratch")
    func segmentDropResumesWithRange() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // One large segment (the paired-grab shape: the whole video is one file) that drops once
        // exactly 4096 delivered bytes in.
        let data = payload(7, 64_000)
        let url = URL(string: "https://cdn/x/whole-video.mp4")!
        let mock = MockHTTPClient(pendingDrops: 1, dropAfterBytes: 4096)
        mock.chunkSize = 1024
        mock.setResource(.init(data: data), for: url)
        let plan = MediaPlan(format: .dash, segments: [MediaSegment(id: 0, url: url, duration: 0)])

        let store = try GRDBDownloadStore.inMemory()
        let manager = try await makeManager(store: store, mock: mock)
        let request = DownloadRequest(url: url, suggestedFileName: "v.mp4", destinationDirectoryPath: dir.path)
        let download = await manager.addMedia(request, plan: plan)
        let done = try await waitFor(manager, download.id) { $0.status == .completed }

        // Byte-perfect despite the drop, and the retry asked for the tail — not the whole file.
        #expect(try Data(contentsOf: URL(fileURLWithPath: done.destinationFilePath)) == data)
        let resume = try #require(mock.lastRequest?.byteRange)
        #expect(resume.lowerBound == 4096)
        #expect(resume.upperBound == Int64(data.count - 1))
    }

    @Test("A server that ignores Range restarts the segment cleanly instead of corrupting it")
    func segmentDropRestartsWithoutRangeSupport() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let data = payload(3, 48_000)
        let url = URL(string: "https://cdn/x/no-ranges.mp4")!
        let mock = MockHTTPClient(pendingDrops: 1, dropAfterBytes: 4096)
        mock.chunkSize = 1024
        mock.setResource(.init(data: data, acceptsRanges: false), for: url)   // 200 + full body always
        let plan = MediaPlan(format: .dash, segments: [MediaSegment(id: 0, url: url, duration: 0)])

        let store = try GRDBDownloadStore.inMemory()
        let manager = try await makeManager(store: store, mock: mock)
        let request = DownloadRequest(url: url, suggestedFileName: "v.mp4", destinationDirectoryPath: dir.path)
        let download = await manager.addMedia(request, plan: plan)
        let done = try await waitFor(manager, download.id) { $0.status == .completed }

        // If the refused resume had been appended, the file would carry duplicate leading bytes.
        #expect(try Data(contentsOf: URL(fileURLWithPath: done.destinationFilePath)) == data)
    }

    @Test("A partial left by a previous run resumes from disk (probing for the unknown end)")
    func relaunchResumesSegmentPartial() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let data = payload(9, 50_000)
        let url = URL(string: "https://cdn/x/relaunch.mp4")!
        let mock = MockHTTPClient()
        mock.setResource(.init(data: data), for: url)
        let plan = MediaPlan(format: .dash, segments: [MediaSegment(id: 0, url: url, duration: 0)])

        let store = try GRDBDownloadStore.inMemory()
        let manager = try await makeManager(store: store, mock: mock)
        let request = DownloadRequest(url: url, suggestedFileName: "v.mp4", destinationDirectoryPath: dir.path)

        // Fabricate the relaunch state: the part dir holds a true prefix left by a "previous run".
        let download = Download(url: url, fileName: "v.mp4", destinationDirectoryPath: dir.path, mediaPlan: plan)
        try FileManager.default.createDirectory(atPath: download.mediaPartDirectoryPath, withIntermediateDirectories: true)
        let partial = (download.mediaPartDirectoryPath as NSString).appendingPathComponent("seg-0.part.partial")
        try data.prefix(12_288).write(to: URL(fileURLWithPath: partial))

        let added = await manager.addMedia(request, plan: plan)
        let done = try await waitFor(manager, added.id) { $0.status == .completed }

        #expect(try Data(contentsOf: URL(fileURLWithPath: done.destinationFilePath)) == data)
        #expect(mock.probeCount >= 1)                                  // learned the end via probe
        let resume = try #require(mock.lastRequest?.byteRange)
        #expect(resume.lowerBound == 12_288)                           // …and continued, not restarted
    }

    @Test("A paired grab reports live bytes and a byte total once both segment sizes are known")
    func pairedGrabReportsByteTotals() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let video = payload(1, 40_000)
        let audio = payload(2, 10_000)
        let videoURL = URL(string: "https://cdn/x/v.mp4")!
        let audioURL = URL(string: "https://cdn/x/a.m4a")!
        let mock = MockHTTPClient()
        mock.chunkSize = 1024
        mock.perChunkDelay = .milliseconds(1)   // slow enough that mid-flight progress events fire
        mock.setResource(.init(data: video), for: videoURL)
        mock.setResource(.init(data: audio), for: audioURL)
        let plan = MediaPlan.pairedFiles(video: videoURL, audio: audioURL)

        let store = try GRDBDownloadStore.inMemory()
        let manager = try await makeManager(store: store, mock: mock)

        // Collect progress events while the grab runs.
        let collector = Task { () -> Bool in
            for await event in manager.progressEvents {
                if case .progress(let progress) = event,
                   progress.totalBytes == Int64(video.count + audio.count),
                   progress.downloadedBytes > 0 {
                    return true   // a live event carried the true byte total
                }
            }
            return false
        }

        let request = DownloadRequest(url: videoURL, suggestedFileName: "v.mp4", destinationDirectoryPath: dir.path)
        let download = await manager.addMedia(request, plan: plan)
        _ = try await waitFor(manager, download.id) { $0.status == .completed }

        // The completion emit is the deterministic backstop (both sizes known, all bytes counted);
        // give it a beat to flow, then end the open stream.
        try await Task.sleep(for: .milliseconds(150))
        collector.cancel()
        let sawTotal = await collector.value
        #expect(sawTotal)
    }

    @Test("Cancelling a media grab discards its part directory")
    func cancelDiscardsParts() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let segURLs = (0..<6).map { URL(string: "https://cdn/x/c\($0).ts")! }
        let mock = MockHTTPClient()
        mock.chunkSize = 512
        mock.perChunkDelay = .milliseconds(8)
        for (index, url) in segURLs.enumerated() { mock.setResource(.init(data: payload(index, 6000)), for: url) }
        let plan = MediaPlan(format: .hls, segments: segURLs.enumerated().map { MediaSegment(id: $0.offset, url: $0.element, duration: 4) })

        let store = try GRDBDownloadStore.inMemory()
        let manager = try await makeManager(store: store, mock: mock)
        let request = DownloadRequest(url: URL(string: "https://cdn/x/c.m3u8")!, suggestedFileName: "c.mp4", destinationDirectoryPath: dir.path)
        let download = await manager.addMedia(request, plan: plan)
        _ = try await waitFor(manager, download.id) { $0.status == .downloading }
        try await Task.sleep(for: .milliseconds(60))
        await manager.cancel(id: download.id)
        _ = try await waitFor(manager, download.id) { $0.status == .canceled }

        #expect(!FileManager.default.fileExists(atPath: download.mediaPartDirectoryPath))
    }
}

private struct MediaTimeout: Error {}
