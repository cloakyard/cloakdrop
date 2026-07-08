import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadPersistence
@testable import DownloadEngine

@Suite("Smart rules applied at add time (through the manager)")
struct SmartRuleEngineIntegrationTests {

    private func makeManager() async throws -> DownloadManager {
        let manager = DownloadManager(
            store: try GRDBDownloadStore.inMemory(),
            httpClient: MockHTTPClient(),
            networkMonitor: AlwaysReachableMonitor()
        )
        try await manager.start()
        return manager
    }

    /// A request that won't try to transfer (so tests can assert the routed record without a server).
    private func pausedRequest(_ urlString: String) -> DownloadRequest {
        var request = DownloadRequest(url: URL(string: urlString)!, destinationDirectoryPath: "/Downloads")
        request.startImmediately = false
        return request
    }

    @Test("A matching rule routes the download's destination, queue, and speed")
    func routesByRule() async throws {
        let manager = try await makeManager()
        let queue = DownloadQueue(name: "Media", maxConcurrentDownloads: 2, order: 1)
        await manager.createQueue(queue)
        await manager.saveRule(SmartRule(
            name: "videos → Media",
            conditions: [.categoryIs(.video)],
            actions: [.setDestination(path: "/Movies", bookmark: nil), .assignQueue(queue.id), .limitSpeed(bytesPerSecond: 750_000)]
        ))

        let download = await manager.add(pausedRequest("https://example.com/clip.mkv"))
        #expect(download.destinationDirectoryPath == "/Movies")
        #expect(download.queueID == queue.id)
        #expect(download.speedLimitBytesPerSecond == 750_000)
    }

    @Test("A non-matching download is left untouched")
    func nonMatchingUntouched() async throws {
        let manager = try await makeManager()
        await manager.saveRule(SmartRule(
            name: "videos", conditions: [.categoryIs(.video)], actions: [.setDestination(path: "/Movies", bookmark: nil)]
        ))
        let download = await manager.add(pausedRequest("https://example.com/report.pdf"))
        #expect(download.destinationDirectoryPath == "/Downloads")
        #expect(download.queueID == DownloadQueue.defaultQueueID)
    }

    @Test("Size conditions fire only when a pre-flight preview supplies the size")
    func sizeConditionUsesPreview() async throws {
        let manager = try await makeManager()
        let queue = DownloadQueue(name: "Big", order: 1)
        await manager.createQueue(queue)
        await manager.saveRule(SmartRule(
            name: "big → queue", conditions: [.largerThan(1_000_000)], actions: [.assignQueue(queue.id)]
        ))

        let url = URL(string: "https://example.com/data.bin")!
        func preview(_ size: Int64?) -> LinkPreview {
            LinkPreview(
                requestedURL: url, finalURL: url, suggestedFileName: "data.bin", totalBytes: size,
                isResumable: true, mimeType: "application/octet-stream", etag: nil,
                plannedSegmentCount: 1, statusCode: 200
            )
        }

        let big = await manager.add(pausedRequest("https://example.com/data.bin"), preview: preview(2_000_000))
        #expect(big.queueID == queue.id)

        // No preview → the size is unknown → the size condition can't fire → default queue.
        let unknown = await manager.add(pausedRequest("https://example.com/data.bin"), preview: nil)
        #expect(unknown.queueID == DownloadQueue.defaultQueueID)
    }

    @Test("saveRule and deleteRule publish the updated rule list")
    func rulesChangedEvents() async throws {
        let manager = try await makeManager()
        let rule = SmartRule(name: "r", conditions: [.categoryIs(.video)])
        await manager.saveRule(rule)
        #expect(await manager.currentRules().count == 1)
        await manager.deleteRule(id: rule.id)
        #expect(await manager.currentRules().isEmpty)
    }

    @Test("Rules persist and still apply across a relaunch")
    func rulesSurviveRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cloak-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbPath = directory.appendingPathComponent("state.sqlite").path

        let manager1 = DownloadManager(store: try GRDBDownloadStore(path: dbPath), httpClient: MockHTTPClient(), networkMonitor: AlwaysReachableMonitor())
        try await manager1.start()
        await manager1.saveRule(SmartRule(
            name: "videos", conditions: [.categoryIs(.video)], actions: [.setDestination(path: "/Movies", bookmark: nil)]
        ))

        // A brand-new manager over the same database file loads the rule and applies it.
        let manager2 = DownloadManager(store: try GRDBDownloadStore(path: dbPath), httpClient: MockHTTPClient(), networkMonitor: AlwaysReachableMonitor())
        try await manager2.start()
        #expect(await manager2.currentRules().count == 1)

        let download = await manager2.add(pausedRequest("https://example.com/clip.mkv"))
        #expect(download.destinationDirectoryPath == "/Movies")
    }
}
