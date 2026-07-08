import Foundation
import Testing
import CryptoKit
@testable import DownloadModels
@testable import DownloadPersistence
@testable import DownloadEngine

/// Multi-mirror scaffolding: registers the same payload at several mirror URLs, wires a manager on an
/// always-reachable network, and adds a multi-source download (primary + failover mirrors). Small
/// segments + fast retries so a modest payload still fans out across several connections.
private struct MirrorHarness {
    let directory: URL
    let store: GRDBDownloadStore
    let mock: MockHTTPClient
    let manager: DownloadManager

    init(payload: Data, liveMirrors: [URL], acceptsRanges: Bool = true) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cloakdrop-metalink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try GRDBDownloadStore.inMemory()
        mock = MockHTTPClient()
        mock.chunkSize = 4096
        for url in liveMirrors {
            mock.setResource(.init(data: payload, acceptsRanges: acceptsRanges, suggestedFilename: "payload.bin"), for: url)
        }
        manager = DownloadManager(store: store, httpClient: mock, networkMonitor: AlwaysReachableMonitor())
        try await manager.start()
        var settings = await manager.currentSettings()
        settings.minimumSegmentSizeBytes = 1024
        settings.defaultSegmentCount = 4
        settings.retryBaseDelaySeconds = 0.01
        settings.retryMaxDelaySeconds = 0.05
        await manager.updateSettings(settings)
    }

    func add(primary: URL, mirrors: [URL], checksum: ChecksumExpectation? = nil) async -> Download {
        await manager.add(DownloadRequest(url: primary, mirrors: mirrors,
                                          destinationDirectoryPath: directory.path, checksum: checksum))
    }

    func waitFor(_ id: UUID, timeout: Duration = .seconds(15),
                 where predicate: @Sendable (Download) -> Bool) async throws -> Download {
        let deadline = ContinuousClock().now + timeout
        while ContinuousClock().now < deadline {
            if let d = await manager.snapshot().downloads.first(where: { $0.id == id }), predicate(d) { return d }
            try await Task.sleep(for: .milliseconds(15))
        }
        throw MirrorTimeout()
    }

    func fileData(_ d: Download) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: d.destinationFilePath)) }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private struct MirrorTimeout: Error {}
private func makePayload(_ n: Int) -> Data { Data((0..<n).map { UInt8($0 % 251) }) }
private func sha256Hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

@Suite("Metalink multi-source transfer")
struct MetalinkMultiSourceTests {

    @Test("A dead primary fails over to a live mirror and completes byte-perfectly")
    func failoverToLiveMirror() async throws {
        let payload = makePayload(120_000)
        let dead = URL(string: "https://dead.example.com/file.bin")!   // never registered → probe + stream 404
        let live = URL(string: "https://live.example.com/file.bin")!
        let h = try await MirrorHarness(payload: payload, liveMirrors: [live])
        defer { h.cleanup() }

        let dl = await h.add(primary: dead, mirrors: [live])
        let done = try await h.waitFor(dl.id) { $0.status == .completed }

        #expect(try h.fileData(done) == payload)          // reassembled entirely from the surviving mirror
        #expect(h.mock.streamedURLs.contains(live))        // the live mirror actually served bytes
    }

    @Test("Segments spread across multiple live mirrors")
    func spreadsAcrossMirrors() async throws {
        let payload = makePayload(240_000)
        let a = URL(string: "https://a.example.com/file.bin")!
        let b = URL(string: "https://b.example.com/file.bin")!
        let c = URL(string: "https://c.example.com/file.bin")!
        let h = try await MirrorHarness(payload: payload, liveMirrors: [a, b, c])
        defer { h.cleanup() }

        let dl = await h.add(primary: a, mirrors: [b, c])
        let done = try await h.waitFor(dl.id) { $0.status == .completed }

        #expect(try h.fileData(done) == payload)
        #expect(done.segments.count > 1)                   // actually split into several connections
        #expect(Set(h.mock.streamedURLs).count >= 2)       // bytes pulled from more than one mirror
    }

    @Test("A Metalink whole-file checksum verifies on a multi-mirror grab")
    func checksumVerifies() async throws {
        let payload = makePayload(80_000)
        let a = URL(string: "https://a.example.com/file.bin")!
        let b = URL(string: "https://b.example.com/file.bin")!
        let h = try await MirrorHarness(payload: payload, liveMirrors: [a, b])
        defer { h.cleanup() }

        let checksum = ChecksumExpectation(algorithm: .sha256, expectedHex: sha256Hex(payload))
        let dl = await h.add(primary: a, mirrors: [b], checksum: checksum)
        let done = try await h.waitFor(dl.id) { $0.status == .completed }

        #expect(done.checksumVerified == true)
    }

    @Test("A mirror that ignores Range (200 full body) fails over instead of corrupting mid-file")
    func mirrorIgnoringRangeFailsOverNotCorrupts() async throws {
        let payload = makePayload(120_000)
        let ranged = URL(string: "https://ranged.example.com/file.bin")!
        let whole = URL(string: "https://whole.example.com/file.bin")!
        let h = try await MirrorHarness(payload: payload, liveMirrors: [ranged])   // ranged: honors Range (206)
        defer { h.cleanup() }
        // A mirror that ignores Range: every request gets 200 + the whole body from byte 0. Appended at
        // a segment's non-zero offset that would stitch byte-0 data into the wrong region of the file.
        h.mock.setResource(.init(data: payload, acceptsRanges: false, suggestedFilename: "payload.bin"), for: whole)

        let dl = await h.add(primary: ranged, mirrors: [whole])
        let done = try await h.waitFor(dl.id) { $0.status == .completed }

        #expect(try h.fileData(done) == payload)   // byte-perfect — the 200 mirror never corrupted a segment
    }

    @Test("Every mirror is tried before giving up, even with a one-retry budget")
    func sweepsAllMirrorsBeforeGivingUp() async throws {
        let payload = makePayload(60_000)
        let dead1 = URL(string: "https://dead1.example.com/file.bin")!   // unregistered → 404
        let dead2 = URL(string: "https://dead2.example.com/file.bin")!   // unregistered → 404
        let live = URL(string: "https://live.example.com/file.bin")!
        let h = try await MirrorHarness(payload: payload, liveMirrors: [live])
        defer { h.cleanup() }
        // With a shared budget, a 1-retry setting would try only two sources — never reaching the live
        // third mirror. Failover must sweep every source regardless of the transient-drop retry budget.
        var settings = await h.manager.currentSettings()
        settings.maxRetryAttempts = 1
        await h.manager.updateSettings(settings)

        let dl = await h.add(primary: dead1, mirrors: [dead2, live])
        let done = try await h.waitFor(dl.id) { $0.status == .completed }

        #expect(try h.fileData(done) == payload)
        #expect(h.mock.streamedURLs.contains(live))
    }

    @Test("A mirror serving a different-sized file is rejected, not stitched in")
    func mismatchedSizeMirrorRejected() async throws {
        let payload = makePayload(120_000)
        let good = URL(string: "https://good.example.com/file.bin")!
        let wrong = URL(string: "https://wrong.example.com/file.bin")!
        let h = try await MirrorHarness(payload: payload, liveMirrors: [good])
        defer { h.cleanup() }
        // A range-honoring mirror, but a DIFFERENT file (different size and content). Its bytes must
        // never be stitched in — even absent a whole-file checksum to catch the corruption afterward.
        let other = Data((0..<90_000).map { UInt8(($0 + 13) % 251) })
        h.mock.setResource(.init(data: other, acceptsRanges: true, suggestedFilename: "payload.bin"), for: wrong)

        let dl = await h.add(primary: good, mirrors: [wrong])
        let done = try await h.waitFor(dl.id) { $0.status == .completed }

        #expect(try h.fileData(done) == payload)   // assembled only from the correctly-sized mirror
    }
}
