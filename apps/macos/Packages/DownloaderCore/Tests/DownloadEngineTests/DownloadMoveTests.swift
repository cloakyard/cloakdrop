import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadPersistence
@testable import DownloadEngine

@Suite("Move unfinished downloads")
struct DownloadMoveTests {
    @Test("A relocated partial resumes after relaunch and never replaces a destination file")
    func moveAndRelaunch() async throws {
        let h = try await DownloadWorkflowHarness()
        defer { h.cleanup() }
        let partial = try await h.partial()
        let folder = h.directory.appendingPathComponent("new-folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let occupied = folder.appendingPathComponent(partial.fileName)
        try Data("keep me".utf8).write(to: occupied)
        try await h.manager.moveDownload(id: partial.id, to: folder, bookmark: nil)
        let moved = try #require(try await h.store.download(id: partial.id))
        #expect(moved.status == .paused)
        #expect(moved.downloadedBytes == partial.downloadedBytes)
        #expect(moved.fileName != partial.fileName)
        #expect(!FileManager.default.fileExists(atPath: partial.partFilePath))
        #expect(try Data(contentsOf: occupied) == Data("keep me".utf8))
        h.mock.setResource(.init(data: h.payload, etag: partial.etag), for: h.source)
        let reloaded = DownloadManager(store: h.store, httpClient: h.mock, networkMonitor: AlwaysReachableMonitor())
        try await reloaded.start()
        await reloaded.resume(id: moved.id)
        let done = try await h.waitFor(moved.id, manager: reloaded)
        #expect(try Data(contentsOf: URL(fileURLWithPath: done.destinationFilePath)) == h.payload)
        #expect(h.mock.streamedRequests.allSatisfy { ($0.byteRange?.lowerBound ?? 0) >= 32_000 })
    }

    @Test("An unavailable destination leaves the source intact")
    func failedMovePreservesSource() async throws {
        let h = try await DownloadWorkflowHarness()
        defer { h.cleanup() }
        let partial = try await h.partial()
        await #expect(throws: DownloadEditError.folderUnavailable) {
            try await h.manager.moveDownload(id: partial.id, to: h.directory.appendingPathComponent("missing"), bookmark: nil)
        }
        #expect(try await h.store.download(id: partial.id) == partial)
        #expect(FileManager.default.fileExists(atPath: partial.partFilePath))
    }

    @Test("Orphan staging files reserve names too")
    func preservesOrphanStaging() async throws {
        let h = try await DownloadWorkflowHarness()
        defer { h.cleanup() }
        let partial = try await h.partial()
        let folder = h.directory.appendingPathComponent("new-folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let orphan = folder.appendingPathComponent(partial.fileName + ".cdpart")
        try Data("unrelated".utf8).write(to: orphan)
        try await h.manager.moveDownload(id: partial.id, to: folder, bookmark: nil)
        let moved = try #require(try await h.store.download(id: partial.id))
        #expect(moved.fileName != partial.fileName)
        #expect(try Data(contentsOf: orphan) == Data("unrelated".utf8))
    }

    @Test("Media segment directories and assembled staging move together")
    func movesMediaStaging() async throws {
        let h = try await DownloadWorkflowHarness()
        defer { h.cleanup() }
        var partial = try await h.partial()
        partial.mediaPlan = .pairedFiles(video: h.source, audio: h.replacement)
        partial.mediaDownloadedBytes = 123
        await h.manager.seedWorkflowRecord(partial)
        let parts = URL(fileURLWithPath: partial.mediaPartDirectoryPath)
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        try Data("segment".utf8).write(to: parts.appendingPathComponent("video-0.part"))
        let folder = h.directory.appendingPathComponent("new-folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await h.manager.moveDownload(id: partial.id, to: folder, bookmark: nil)
        let moved = try #require(try await h.store.download(id: partial.id))
        #expect(moved.mediaPlan == partial.mediaPlan)
        #expect(FileManager.default.fileExists(atPath: moved.partFilePath))
        #expect(try Data(contentsOf: URL(fileURLWithPath: moved.mediaPartDirectoryPath).appendingPathComponent("video-0.part"))
                == Data("segment".utf8))
        #expect(!FileManager.default.fileExists(atPath: partial.mediaPartDirectoryPath))
    }
}
