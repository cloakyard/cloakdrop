import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadPersistence
@testable import DownloadEngine

@Suite("FTP client (loopback server)")
struct FTPClientIntegrationTests {
    private func collect(_ stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var out = Data()
        for try await chunk in stream { out.append(chunk) }
        return out
    }

    @Test("Probes size and downloads the whole file over FTP")
    func fullDownload() async throws {
        let payload = Data((0..<50_000).map { UInt8($0 % 251) })
        let server = try LoopbackFTPServer(payload: payload)
        try await server.start()
        defer { server.stop() }

        let client = FTPClient()
        let request = HTTPDownloadRequest(url: server.baseURL)

        let head = try await client.probe(request)
        #expect(head.totalBytes == Int64(payload.count))
        #expect(head.acceptsRanges)

        let (streamHead, stream) = try await client.stream(request)
        #expect(streamHead.statusCode == 200)   // whole-file fetch is a 200
        let body = try await collect(stream)
        #expect(body == payload)
    }

    @Test("Resumes from a byte offset via REST and reports 206 (what the engine's range guard requires)")
    func restResume() async throws {
        let payload = Data((0..<40_000).map { UInt8(($0 * 7) % 251) })
        let server = try LoopbackFTPServer(payload: payload)
        try await server.start()
        defer { server.stop() }

        let client = FTPClient()
        let offset: Int64 = 10_000
        let end: Int64 = 19_999
        let request = HTTPDownloadRequest(url: server.baseURL, byteRange: offset...end)

        let (head, stream) = try await client.stream(request)
        // A ranged FTP answer MUST look like HTTP 206, or the engine's mirrorServesThisSegment guard
        // rejects every offset>0 segment and multi-segment/resume silently break.
        #expect(head.statusCode == 206)
        let body = try await collect(stream)
        #expect(body.count == Int(end - offset + 1))
        #expect(body == payload.subdata(in: Int(offset)..<Int(end + 1)))
    }

    @Test("A multi-segment FTP download completes byte-perfectly through the full engine")
    func multiSegmentThroughEngine() async throws {
        // Large enough to split into several segments (each does REST+RETR on its own connection).
        let payload = Data((0..<200_000).map { UInt8(($0 * 13 + 7) % 251) })
        let server = try LoopbackFTPServer(payload: payload)
        try await server.start()
        defer { server.stop() }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloakdrop-ftp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try GRDBDownloadStore.inMemory()
        let manager = DownloadManager(store: store, httpClient: FTPClient(), networkMonitor: AlwaysReachableMonitor())
        try await manager.start()
        var settings = await manager.currentSettings()
        settings.minimumSegmentSizeBytes = 1024
        settings.defaultSegmentCount = 4
        settings.retryBaseDelaySeconds = 0.01
        settings.retryMaxDelaySeconds = 0.05
        settings.generateProvenanceReceipts = false
        await manager.updateSettings(settings)

        let request = DownloadRequest(url: server.baseURL, destinationDirectoryPath: directory.path)
        let id = await manager.add(request).id

        let deadline = ContinuousClock().now + .seconds(20)
        var completed: Download?
        while ContinuousClock().now < deadline {
            if let d = await manager.snapshot().downloads.first(where: { $0.id == id }) {
                if case .failed = d.status { completed = d; break }
                if d.status == .completed { completed = d; break }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let download = try #require(completed)
        #expect(download.status == .completed)
        // Must have actually split into multiple segments — otherwise the range guard was never exercised.
        #expect(download.segments.count > 1)
        let written = try Data(contentsOf: URL(fileURLWithPath: download.destinationFilePath))
        #expect(written == payload)
    }
}
