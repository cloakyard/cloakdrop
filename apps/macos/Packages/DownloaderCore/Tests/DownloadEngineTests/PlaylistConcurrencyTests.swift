import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadPersistence
@testable import DownloadEngine

@Suite("Concurrent playlist imports")
struct PlaylistConcurrencyTests {
    @Test("Overlapping imports never enqueue the same page twice")
    func concurrentImports() async throws {
        let h = try await DownloadWorkflowHarness()
        defer { h.cleanup() }
        let store = SuspendedPlaylistStore(base: h.store)
        let manager = DownloadManager(store: store, httpClient: h.mock, networkMonitor: AlwaysReachableMonitor(),
                                      mediaExtractor: UnusedPlaylistExtractor())
        try await manager.start()
        let playlist = MediaPlaylist(title: "Lessons", entries: [
            .init(index: 1, title: "First", pageURL: URL(string: "https://example.com/one")),
            .init(index: 2, title: "Second", pageURL: URL(string: "https://example.com/two"))
        ])
        await store.holdNextSave()
        let first = Task {
            try await manager.addPlaylist(playlist, selectedIDs: [1, 2], selection: .init(),
                                          directory: h.directory, bookmark: nil, startImmediately: false)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await store.isBlocked), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard await store.isBlocked else {
            first.cancel()
            Issue.record("The first import did not reach its persistence checkpoint")
            return
        }
        let second: [Download]
        do {
            second = try await manager.addPlaylist(playlist, selectedIDs: [1, 2], selection: .init(),
                                                   directory: h.directory, bookmark: nil, startImmediately: false)
        } catch {
            await store.release()
            _ = try? await first.value
            throw error
        }
        await store.release()
        let initial = try await first.value
        let saved = try await store.allDownloads()
        #expect(initial.count + second.count == 2)
        #expect(saved.count == 2)
        #expect(Set(saved.map(\.url)).count == 2)
    }
}

private struct UnusedPlaylistExtractor: MediaExtractor {
    func version() async -> String? { "test" }
    func extract(pageURL: URL, cookies: ExtractionCookies?, userAgent: String?) async throws -> ExtractedMedia {
        throw MediaExtractionError.noGrabbableFormats
    }
}

private actor SuspendedPlaylistStore: DownloadStore {
    let base: GRDBDownloadStore
    private var shouldHold = false
    private var pending: CheckedContinuation<Void, Never>?
    var isBlocked: Bool { pending != nil }
    init(base: GRDBDownloadStore) { self.base = base }
    func holdNextSave() { shouldHold = true }
    func release() { pending?.resume(); pending = nil }
    func bootstrap() async throws { try await base.bootstrap() }
    func allDownloads() async throws -> [Download] { try await base.allDownloads() }
    func download(id: UUID) async throws -> Download? { try await base.download(id: id) }
    func save(_ download: Download) async throws {
        if shouldHold {
            shouldHold = false
            await withCheckedContinuation { pending = $0 }
        }
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
