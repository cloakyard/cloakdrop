import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadPersistence
@testable import DownloadEngine

/// End-to-end tests over real TCP/HTTP using `URLSessionHTTPClient` against a loopback
/// server, validating the production networking path (probe, Range, reassembly).
@Suite("Loopback integration (real URLSession)", .serialized)
struct LoopbackIntegrationTests {

    private func makePayload(_ n: Int) -> Data { Data((0..<n).map { UInt8($0 % 251) }) }

    @Test("Probe reports size and range support from a real server")
    func probe() async throws {
        let payload = makePayload(123_456)
        let server = try LoopbackHTTPServer(payload: payload, acceptsRanges: true)
        try await server.start()
        defer { server.stop() }

        let client = URLSessionHTTPClient()
        let head = try await client.probe(HTTPDownloadRequest(url: server.baseURL.appendingPathComponent("file.bin")))
        #expect(head.totalBytes == Int64(payload.count))
        #expect(head.acceptsRanges == true)
    }

    @Test("Multi-segment download over real HTTP reassembles byte-perfectly")
    func multiSegment() async throws {
        let payload = makePayload(256_000)
        let server = try LoopbackHTTPServer(payload: payload, acceptsRanges: true)
        try await server.start()
        defer { server.stop() }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cloakdrop-loopback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try GRDBDownloadStore.inMemory()
        let manager = DownloadManager(
            store: store,
            httpClient: URLSessionHTTPClient(),
            networkMonitor: AlwaysReachableMonitor()
        )
        try await manager.start()
        var settings = await manager.currentSettings()
        settings.minimumSegmentSizeBytes = 1024
        settings.defaultSegmentCount = 4
        await manager.updateSettings(settings)

        let added = await manager.add(DownloadRequest(
            url: server.baseURL.appendingPathComponent("payload.bin"),
            suggestedFileName: "payload.bin",
            destinationDirectoryPath: directory.path
        ))

        let deadline = ContinuousClock().now + .seconds(20)
        var done: Download?
        while ContinuousClock().now < deadline {
            if let d = await manager.snapshot().downloads.first(where: { $0.id == added.id }), d.status == .completed {
                done = d; break
            }
            if let d = await manager.snapshot().downloads.first(where: { $0.id == added.id }), case .failed(let reason) = d.status {
                Issue.record("download failed: \(reason)"); break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let finished = try #require(done)
        #expect(finished.segments.count > 1)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: finished.destinationFilePath))
        #expect(bytes == payload)
    }
}
