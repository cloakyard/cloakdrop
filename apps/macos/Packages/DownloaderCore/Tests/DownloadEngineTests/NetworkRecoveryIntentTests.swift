import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadPersistence
@testable import DownloadEngine

@Suite("Manual intent during network recovery")
struct NetworkRecoveryIntentTests {
    @Test("Reconnection respects pause, pause-all and move, while untouched work resumes",
          arguments: ["pause", "pauseAll", "move", "none"])
    func manualIntentWhileOffline(action: String) async throws {
        let h = try await DownloadWorkflowHarness()
        defer { h.cleanup() }
        let monitor = WorkflowNetworkMonitor()
        let manager = DownloadManager(store: h.store, httpClient: h.mock, networkMonitor: monitor)
        try await manager.start()
        h.mock.chunkSize = 1024
        h.mock.perChunkDelay = .milliseconds(20)
        h.mock.setResource(.init(data: h.payload), for: h.source)
        let item = await manager.add(DownloadRequest(url: h.source, destinationDirectoryPath: h.directory.path))
        _ = try await h.waitFor(item.id, manager: manager) { $0.status == .downloading }
        monitor.send(false)
        _ = try await h.waitFor(item.id, manager: manager) { $0.status == .paused }
        switch action {
        case "pause": await manager.pause(id: item.id)
        case "pauseAll": await manager.pauseAll()
        case "move":
            let destination = h.directory.appendingPathComponent("moved")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try await manager.moveDownload(id: item.id, to: destination, bookmark: nil)
        default: break
        }
        monitor.send(true)
        if action == "none" {
            let done = try await h.waitFor(item.id, manager: manager)
            #expect(try Data(contentsOf: URL(fileURLWithPath: done.destinationFilePath)) == h.payload)
            return
        }
        // Allow the asynchronous path-monitor event to reach the manager and any restarted worker.
        try await Task.sleep(for: .milliseconds(150))
        try #require(await manager.networkReachable)
        #expect(await manager.snapshot().downloads.first { $0.id == item.id }?.status == .paused)
        await manager.pauseAll()
    }
}

private final class WorkflowNetworkMonitor: NetworkPathMonitoring, Sendable {
    private let stream: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func reachabilityUpdates() -> AsyncStream<Bool> { stream }
    func send(_ reachable: Bool) { continuation.yield(reachable) }
    deinit { continuation.finish() }
}
