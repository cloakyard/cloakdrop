import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadPersistence
@testable import DownloadEngine

@Suite("Security-scoped destination recovery")
struct SecurityScopeTests {
    @Test("Cancel and remove clean the moved staging paths of paused ordinary and media downloads",
          arguments: [false, true], [false, true])
    func movedFolderCleanup(isMedia: Bool, remove: Bool) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bookmark-cleanup-\(UUID())")
        let original = root.appendingPathComponent("original")
        let moved = root.appendingPathComponent("moved")
        try fm.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = URL(string: "https://example.com/file.ts")!
        var download = Download(url: source, fileName: "file.ts", destinationDirectoryPath: original.path,
                                destinationBookmark: try original.bookmarkData(options: .withSecurityScope))
        download.status = .paused
        if isMedia {
            download.mediaPlan = MediaPlan(format: .hls, segments: [MediaSegment(id: 0, url: source, duration: 1)])
            try fm.createDirectory(atPath: download.mediaPartDirectoryPath, withIntermediateDirectories: true)
            try Data("media".utf8).write(to: URL(fileURLWithPath: download.mediaPartDirectoryPath)
                .appendingPathComponent("seg-0.part"))
        } else {
            try Data("part".utf8).write(to: URL(fileURLWithPath: download.partFilePath))
        }
        try Data("finished".utf8).write(to: URL(fileURLWithPath: download.destinationFilePath))
        let store = try GRDBDownloadStore.inMemory()
        try await store.bootstrap()
        try await store.save(download)
        try fm.moveItem(at: original, to: moved)
        let manager = DownloadManager(store: store, httpClient: MockHTTPClient(), networkMonitor: AlwaysReachableMonitor())
        try await manager.start()
        if remove { await manager.remove(id: download.id, deleteFile: true) } else { await manager.cancel(id: download.id) }
        #expect(!fm.fileExists(atPath: moved.appendingPathComponent("file.ts.cdpart").path))
        #expect(!fm.fileExists(atPath: moved.appendingPathComponent("file.ts.cdparts").path))
        #expect(fm.fileExists(atPath: moved.appendingPathComponent("file.ts").path) == !remove)
        #expect(!fm.fileExists(atPath: original.path))
    }

    @Test("Moved bookmarked folders preserve ordinary and media resume data, including category descendants",
          arguments: [false, true], [false, true])
    func movedFolderResumes(isMedia: Bool, useCategory: Bool) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bookmark-resume-\(UUID())")
        let original = root.appendingPathComponent("original")
        let moved = root.appendingPathComponent("moved")
        let destination = useCategory ? original.appendingPathComponent("Video") : original
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let bookmark = try original.bookmarkData(options: .withSecurityScope)
        let source = URL(string: "https://example.com/first.ts")!
        let second = URL(string: "https://example.com/second.ts")!
        let expected = Data("abcdefgh".utf8)
        let client = MockHTTPClient(resources: [
            source: .init(data: isMedia ? Data(expected.prefix(4)) : expected),
            second: .init(data: Data(expected.suffix(4)))
        ])
        var download = Download(url: source, fileName: isMedia ? "video.ts" : "file.bin",
                                destinationDirectoryPath: destination.path, destinationBookmark: bookmark,
                                totalBytes: isMedia ? nil : 8, supportsResume: !isMedia,
                                segments: isMedia ? [] : [DownloadSegment(id: 0, start: 0, end: 7, downloadedBytes: 4)])
        download.status = .paused
        if isMedia {
            download.mediaPlan = MediaPlan(format: .hls, segments: [
                MediaSegment(id: 0, url: source, duration: 1),
                MediaSegment(id: 1, url: second, duration: 1)
            ])
            try fm.createDirectory(atPath: download.mediaPartDirectoryPath, withIntermediateDirectories: true)
            try expected.prefix(4).write(to: URL(fileURLWithPath: download.mediaPartDirectoryPath)
                .appendingPathComponent("seg-0.part"))
        } else {
            try Data("abcdxxxx".utf8).write(to: URL(fileURLWithPath: download.partFilePath))
        }
        let store = try GRDBDownloadStore.inMemory()
        try await store.bootstrap()
        try await store.save(download)
        try fm.moveItem(at: original, to: moved)
        let staleScope = SecurityScope(bookmark: bookmark)
        #expect(staleScope.isStale)
        let restored = try #require(await store.download(id: download.id))
        let result = await task(restored, client: client, store: store).run()
        #expect(result.status == .completed)
        let expectedDirectory = useCategory ? moved.appendingPathComponent("Video") : moved
        #expect(URL(fileURLWithPath: result.destinationDirectoryPath).resolvingSymlinksInPath()
            == expectedDirectory.resolvingSymlinksInPath())
        #expect(try Data(contentsOf: URL(fileURLWithPath: result.destinationFilePath)) == expected)
        #expect(!fm.fileExists(atPath: original.path))
        #expect(client.streamCount == 1)
        if isMedia {
            #expect(client.streamedURLs == [second])
        } else {
            #expect(client.streamedRequests.first?.byteRange == 4...7)
        }
        let saved = try #require(await store.download(id: download.id))
        #expect(saved.destinationDirectoryPath == result.destinationDirectoryPath)
        #expect(saved.destinationBookmark != bookmark)
        #expect(!SecurityScope(bookmark: saved.destinationBookmark).isStale)
    }

    @Test("A stale bookmark resolving to a replacement at its old path cannot overwrite or delete unrelated files")
    func replacedDirectoryFailsSafely() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bookmark-replacement-\(UUID())")
        let original = root.appendingPathComponent("original")
        let moved = root.appendingPathComponent("moved")
        try fm.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let bookmark = try original.bookmarkData(options: .withSecurityScope)
        let source = URL(string: "https://example.com/file.bin")!
        let download = Download(url: source, fileName: "file.bin", destinationDirectoryPath: original.path,
                                destinationBookmark: bookmark, totalBytes: 8, supportsResume: true,
                                segments: [DownloadSegment(id: 0, start: 0, end: 7, downloadedBytes: 4)])
        try Data("abcdxxxx".utf8).write(to: URL(fileURLWithPath: download.partFilePath))
        try fm.moveItem(at: original, to: moved)
        try fm.createDirectory(at: original, withIntermediateDirectories: true)
        let sentinel = Data("unrelated".utf8)
        try sentinel.write(to: URL(fileURLWithPath: download.partFilePath))
        try sentinel.write(to: URL(fileURLWithPath: download.destinationFilePath))
        let client = MockHTTPClient(resources: [source: .init(data: Data("abcdefgh".utf8))])
        let store = try GRDBDownloadStore.inMemory()
        try await store.bootstrap()
        let result = await task(download, client: client, store: store).run()
        guard case .failed = result.status else { Issue.record("Ambiguous stale bookmark was accepted"); return }
        SegmentedFileWriter.discardPartData(for: result, deleteFile: true)
        #expect(client.probeCount == 0)
        #expect(try Data(contentsOf: URL(fileURLWithPath: download.partFilePath)) == sentinel)
        #expect(try Data(contentsOf: URL(fileURLWithPath: download.destinationFilePath)) == sentinel)
        #expect(try Data(contentsOf: moved.appendingPathComponent("file.bin.cdpart")) == Data("abcdxxxx".utf8))
    }

    @Test("A valid bookmark never authorizes an unrelated stored destination")
    func unrelatedDestinationFailsBeforeIO() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bookmark-mismatch-\(UUID())")
        let chosen = root.appendingPathComponent("chosen")
        let unrelated = root.appendingPathComponent("chosen-other")
        try fm.createDirectory(at: chosen, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let bookmark = try chosen.bookmarkData(options: .withSecurityScope)
        let source = URL(string: "https://example.com/file.bin")!
        let download = Download(url: source, fileName: "file.bin", destinationDirectoryPath: unrelated.path,
                                destinationBookmark: bookmark)
        let client = MockHTTPClient(resources: [source: .init(data: Data("file".utf8))])
        let store = try GRDBDownloadStore.inMemory()
        try await store.bootstrap()
        let result = await task(download, client: client, store: store).run()
        guard case .failed = result.status else { Issue.record("Mismatched bookmark was accepted"); return }
        #expect(client.probeCount == 0)
        #expect(client.streamCount == 0)
        #expect(!fm.fileExists(atPath: unrelated.path))
    }

    private func task(_ download: Download, client: MockHTTPClient, store: GRDBDownloadStore) -> DownloadTask {
        DownloadTask(download: download, httpClient: client, store: store,
                     globalLimiter: BandwidthLimiter(bytesPerSecond: nil),
                     settings: EngineSettings(autoDiscoverChecksums: false, assessSignatures: false,
                                              applyQuarantine: false, generateProvenanceReceipts: false), emit: { _ in })
    }
}
