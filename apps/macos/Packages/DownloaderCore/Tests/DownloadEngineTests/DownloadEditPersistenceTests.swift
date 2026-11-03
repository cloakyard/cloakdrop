import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadPersistence
@testable import DownloadEngine

@Suite("Download edit persistence failures")
struct DownloadEditPersistenceTests {
    @Test("A failed move commit keeps the original and removes only its own copies")
    func moveRollback() async throws {
        let h = try await DownloadWorkflowHarness()
        defer { h.cleanup() }
        let partial = try await h.partial()
        let destination = h.directory.appendingPathComponent("move-target")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let unrelated = destination.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: unrelated)
        let store = EditingFailureStore(base: h.store)
        let manager = DownloadManager(store: store, httpClient: h.mock, networkMonitor: AlwaysReachableMonitor())
        try await manager.start()
        await store.rejectDownloadSaves()
        await #expect(throws: EditingFailure.self) {
            try await manager.moveDownload(id: partial.id, to: destination, bookmark: nil)
        }
        #expect(try await h.store.download(id: partial.id) == partial)
        #expect(await manager.snapshot().downloads.first == partial)
        #expect(FileManager.default.fileExists(atPath: partial.partFilePath))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["unrelated.txt"])
    }

    @Test("A failed repair commit never discards saved progress, even with explicit restart")
    func repairRollback() async throws {
        let h = try await DownloadWorkflowHarness()
        defer { h.cleanup() }
        let partial = try await h.partial()
        h.mock.setResource(.init(data: h.payload), for: h.replacement)
        let store = EditingFailureStore(base: h.store)
        let manager = DownloadManager(store: store, httpClient: h.mock, networkMonitor: AlwaysReachableMonitor())
        try await manager.start()
        await store.rejectDownloadSaves()
        await #expect(throws: EditingFailure.self) {
            try await manager.repairDownload(id: partial.id, replacementURL: h.replacement, restart: true)
        }
        #expect(try await h.store.download(id: partial.id) == partial)
        #expect(await manager.snapshot().downloads.first == partial)
        #expect(try Data(contentsOf: URL(fileURLWithPath: partial.partFilePath)).prefix(32_000) == h.payload.prefix(32_000))
    }
}

private struct EditingFailure: Error {}

private actor EditingFailureStore: DownloadStore {
    let base: GRDBDownloadStore
    var rejecting = false
    init(base: GRDBDownloadStore) { self.base = base }
    func rejectDownloadSaves() { rejecting = true }
    func bootstrap() async throws { try await base.bootstrap() }
    func allDownloads() async throws -> [Download] { try await base.allDownloads() }
    func download(id: UUID) async throws -> Download? { try await base.download(id: id) }
    func save(_ download: Download) async throws {
        if rejecting { throw EditingFailure() }
        try await base.save(download)
    }
    func delete(id: UUID) async throws { try await base.delete(id: id) }
    func deleteCompleted() async throws { try await base.deleteCompleted() }
    func allQueues() async throws -> [DownloadQueue] { try await base.allQueues() }
    func save(_ queue: DownloadQueue) async throws { try await base.save(queue) }
    func deleteQueue(id: UUID) async throws { try await base.deleteQueue(id: id) }
    func allRules() async throws -> [SmartRule] { try await base.allRules() }
    func save(_ rule: SmartRule) async throws { try await base.save(rule) }
    func deleteRule(id: UUID) async throws { try await base.deleteRule(id: id) }
    func loadSettings() async throws -> EngineSettings { try await base.loadSettings() }
    func save(settings: EngineSettings) async throws { try await base.save(settings: settings) }
    func recordDownloadedBytes(_ bytes: Int64, on date: Date) async throws { try await base.recordDownloadedBytes(bytes, on: date) }
    func loadStats(asOf date: Date) async throws -> DownloadStats { try await base.loadStats(asOf: date) }
    func resetStats() async throws { try await base.resetStats() }
}
