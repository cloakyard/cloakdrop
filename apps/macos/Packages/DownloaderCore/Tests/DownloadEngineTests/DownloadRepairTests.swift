import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadPersistence
@testable import DownloadEngine

@Suite("Download repair")
struct DownloadRepairTests {
    @Test("A validator on a different resource path is not proof of compatible content")
    func differentPathRequiresRestart() async throws {
        let h = try await DownloadWorkflowHarness()
        defer { h.cleanup() }
        let partial = try await h.partial()
        let url = URL(string: "https://example.com/different.bin")!
        h.mock.setResource(.init(data: h.payload, etag: partial.etag), for: url)
        await #expect(throws: DownloadEditError.restartRequired) {
            try await h.manager.repairDownload(id: partial.id, replacementURL: url)
        }
    }

    @Test("An expired address is replaced without re-fetching compatible saved bytes")
    func repairsPartial() async throws {
        let h = try await DownloadWorkflowHarness()
        defer { h.cleanup() }
        let partial = try await h.partial()
        h.mock.setResource(.init(data: h.payload, etag: partial.etag), for: h.replacement)
        try await h.manager.repairDownload(id: partial.id, replacementURL: h.replacement)
        let done = try await h.waitFor(partial.id)
        #expect(try Data(contentsOf: URL(fileURLWithPath: done.destinationFilePath)) == h.payload)
        #expect(h.mock.streamedRequests.allSatisfy { $0.url == h.replacement && ($0.byteRange?.lowerBound ?? 0) >= 32_000 })
        #expect(try await h.store.download(id: done.id)?.url == h.replacement)
    }

    @Test("Missing, weak, different and cross-origin validators require an explicit restart")
    func rejectsUnprovenReplacements() async throws {
        for tag in [nil, "W/\"version-one\"", "\"version-two\"", "\"version-one\""] as [String?] {
            let h = try await DownloadWorkflowHarness()
            defer { h.cleanup() }
            let partial = try await h.partial()
            let url = tag == partial.etag ? URL(string: "https://other.example/file.bin")! : h.replacement
            h.mock.setResource(.init(data: h.payload, etag: tag), for: url)
            await #expect(throws: DownloadEditError.restartRequired) {
                try await h.manager.repairDownload(id: partial.id, replacementURL: url)
            }
            let unchanged = try #require(try await h.store.download(id: partial.id))
            #expect(unchanged.url == partial.url)
            #expect(unchanged.downloadedBytes == 32_000)
            #expect(h.mock.streamedRequests.isEmpty)
        }
    }

    @Test("Explicit restart replaces progress, drops cross-origin credentials and old mirrors")
    func restartClearsStaleState() async throws {
        let h = try await DownloadWorkflowHarness()
        defer { h.cleanup() }
        var partial = try await h.partial()
        partial.requestHeaders = ["Authorization": "Bearer secret", "Cookie": "session=secret"]
        partial.username = "user"
        partial.password = "secret"
        partial.mirrors = [h.source]
        await h.manager.seedWorkflowRecord(partial)
        let url = URL(string: "https://other.example/file.bin")!
        let data = Data(repeating: 42, count: 64_000)
        h.mock.setResource(.init(data: data, etag: "\"v2\""), for: url)
        try await h.manager.repairDownload(id: partial.id, replacementURL: url, restart: true)
        let done = try await h.waitFor(partial.id)
        #expect(try Data(contentsOf: URL(fileURLWithPath: done.destinationFilePath)) == data)
        #expect(done.mirrors == nil)
        #expect(h.mock.streamedRequests.allSatisfy { $0.username == nil && $0.password == nil && $0.headers["Cookie"] == nil })
    }

    @Test("An unreachable replacement leaves the original data and record intact")
    func failedProbeDoesNotMutate() async throws {
        let h = try await DownloadWorkflowHarness()
        defer { h.cleanup() }
        let partial = try await h.partial()
        await #expect(throws: (any Error).self) {
            try await h.manager.repairDownload(id: partial.id, replacementURL: h.replacement, restart: true)
        }
        #expect(try await h.store.download(id: partial.id) == partial)
        #expect(try Data(contentsOf: URL(fileURLWithPath: partial.partFilePath)).prefix(32_000) == h.payload.prefix(32_000))
    }
}
