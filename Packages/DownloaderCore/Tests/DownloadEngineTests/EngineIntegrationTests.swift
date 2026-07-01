import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadPersistence
@testable import DownloadEngine

/// Shared scaffolding: a temp download directory, an in-memory store, a mock server, and a
/// manager wired to an always-reachable network. Each instance is isolated to one test.
private struct Harness {
    let directory: URL
    let store: GRDBDownloadStore
    let mock: MockHTTPClient
    let manager: DownloadManager
    let url = URL(string: "https://example.com/payload.bin")!

    init(data: Data, acceptsRanges: Bool = true, pendingDrops: Int = 0, dropAfterBytes: Int = 0) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cloakdrop-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try GRDBDownloadStore.inMemory()
        mock = MockHTTPClient(pendingDrops: pendingDrops, dropAfterBytes: dropAfterBytes)
        mock.chunkSize = 4096
        mock.setResource(.init(data: data, acceptsRanges: acceptsRanges, suggestedFilename: "payload.bin"), for: url)
        manager = DownloadManager(store: store, httpClient: mock, networkMonitor: AlwaysReachableMonitor())
        try await manager.start()
        // Small segments so test payloads still split into several connections.
        var settings = await manager.currentSettings()
        settings.minimumSegmentSizeBytes = 1024
        settings.defaultSegmentCount = 4
        settings.retryBaseDelaySeconds = 0.01
        settings.retryMaxDelaySeconds = 0.05
        await manager.updateSettings(settings)
    }

    func request(checksum: ChecksumExpectation? = nil) -> DownloadRequest {
        DownloadRequest(url: url, destinationDirectoryPath: directory.path, checksum: checksum)
    }

    func waitFor(
        _ id: UUID,
        timeout: Duration = .seconds(15),
        where predicate: @Sendable (Download) -> Bool
    ) async throws -> Download {
        let deadline = ContinuousClock().now + timeout
        while ContinuousClock().now < deadline {
            if let download = await manager.snapshot().downloads.first(where: { $0.id == id }), predicate(download) {
                return download
            }
            try await Task.sleep(for: .milliseconds(15))
        }
        throw HarnessTimeout()
    }

    func fileData(_ download: Download) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: download.destinationFilePath))
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private struct HarnessTimeout: Error {}

/// Deterministic, content-checkable payload.
private func makePayload(_ count: Int) -> Data {
    Data((0..<count).map { UInt8($0 % 251) })
}

@Suite("Engine integration (mock server)")
struct EngineIntegrationTests {

    @Test("Multi-segment download completes and reassembles byte-perfectly")
    func multiSegmentCompletes() async throws {
        let payload = makePayload(200_000)
        let h = try await Harness(data: payload)
        defer { h.cleanup() }

        let download = await h.manager.add(h.request())
        let done = try await h.waitFor(download.id) { $0.status == .completed }

        #expect(done.segments.count > 1)               // actually split
        #expect(try h.fileData(done) == payload)        // exact reassembly
        #expect(done.totalBytes == Int64(payload.count))
        #expect(!FileManager.default.fileExists(atPath: done.partFilePath))  // part file cleaned up
    }

    @Test("Falls back to a single stream when the server lacks Range support")
    func singleStreamFallback() async throws {
        let payload = makePayload(120_000)
        let h = try await Harness(data: payload, acceptsRanges: false)
        defer { h.cleanup() }

        let download = await h.manager.add(h.request())
        let done = try await h.waitFor(download.id) { $0.status == .completed }

        #expect(done.segments.count == 1)
        #expect(done.supportsResume == false)
        #expect(try h.fileData(done) == payload)
    }

    @Test("Resumes and completes after injected mid-transfer connection drops")
    func resumesAfterDrops() async throws {
        let payload = makePayload(200_000)
        let h = try await Harness(data: payload, pendingDrops: 3, dropAfterBytes: 2048)
        defer { h.cleanup() }

        let download = await h.manager.add(h.request())
        let done = try await h.waitFor(download.id) { $0.status == .completed }

        #expect(try h.fileData(done) == payload)        // still byte-perfect after retries
        #expect(h.mock.streamCount > done.segments.count) // retries actually happened
    }

    @Test("Verifies a correct checksum and fails a wrong one")
    func checksumVerification() async throws {
        let payload = makePayload(50_000)
        let sha = try sha256Hex(payload)

        let good = try await Harness(data: payload)
        defer { good.cleanup() }
        let okDownload = await good.manager.add(good.request(checksum: .init(algorithm: .sha256, expectedHex: sha)))
        let okDone = try await good.waitFor(okDownload.id) { $0.status == .completed }
        #expect(okDone.checksumVerified == true)

        let bad = try await Harness(data: payload)
        defer { bad.cleanup() }
        let badDownload = await bad.manager.add(bad.request(checksum: .init(algorithm: .sha256, expectedHex: String(repeating: "a", count: 64))))
        let badDone = try await bad.waitFor(badDownload.id) { if case .failed = $0.status { return true } else { return false } }
        if case .failed = badDone.status {} else { Issue.record("expected checksum failure") }
    }

    @Test("Auto-discovers a sibling checksum file and verifies against it")
    func checksumAutoDiscovery() async throws {
        let payload = makePayload(50_000)
        let sha = try sha256Hex(payload)
        let sibling = URL(string: "https://example.com/payload.bin.sha256")!

        // Happy path: a sibling .sha256 with the right digest → verified, and the discovered
        // expectation is recorded on the download (so the inspector can show it).
        let ok = try await Harness(data: payload)
        defer { ok.cleanup() }
        ok.mock.setResource(.init(data: Data("\(sha)  payload.bin\n".utf8), acceptsRanges: false), for: sibling)
        var okRequest = ok.request()
        okRequest.username = "alice"   // the sibling fetch must reuse the download's credentials
        let okID = await ok.manager.add(okRequest)
        let okDone = try await ok.waitFor(okID.id) { $0.status == .completed }
        #expect(okDone.checksumVerified == true)
        #expect(okDone.checksum?.algorithm == .sha256)
        #expect(okDone.checksum?.expectedHex == sha)
        #expect(ok.mock.lastRequest?.url == sibling)        // discovery hit the sibling…
        #expect(ok.mock.lastRequest?.username == "alice")   // …carrying the download's auth

        // Mismatch: an auto-discovered digest that doesn't match only *flags* the file — it stays
        // completed (unlike a user-supplied checksum, which fails the download).
        let bad = try await Harness(data: payload)
        defer { bad.cleanup() }
        bad.mock.setResource(.init(data: Data(String(repeating: "b", count: 64).utf8), acceptsRanges: false), for: sibling)
        let badID = await bad.manager.add(bad.request())
        let badDone = try await bad.waitFor(badID.id) { $0.status == .completed }
        #expect(badDone.checksumVerified == false)

        // No sibling published → completes with no verification (never an error).
        let none = try await Harness(data: payload)
        defer { none.cleanup() }
        let noneID = await none.manager.add(none.request())
        let noneDone = try await none.waitFor(noneID.id) { $0.status == .completed }
        #expect(noneDone.checksum == nil)
        #expect(noneDone.checksumVerified == nil)

        // Discovery disabled → the sibling is never fetched even though it exists.
        let off = try await Harness(data: payload)
        defer { off.cleanup() }
        off.mock.setResource(.init(data: Data("\(sha)  payload.bin\n".utf8), acceptsRanges: false), for: sibling)
        var settings = await off.manager.currentSettings()
        settings.autoDiscoverChecksums = false
        await off.manager.updateSettings(settings)
        let offID = await off.manager.add(off.request())
        let offDone = try await off.waitFor(offID.id) { $0.status == .completed }
        #expect(offDone.checksum == nil)
        #expect(offDone.checksumVerified == nil)

        // Placeholder (all-zero) sibling → unverifiable, not a mismatch: recorded but verified nil.
        let zero = try await Harness(data: payload)
        defer { zero.cleanup() }
        zero.mock.setResource(.init(data: Data("\(String(repeating: "0", count: 64))  payload.bin\n".utf8),
                                    acceptsRanges: false), for: sibling)
        let zeroID = await zero.manager.add(zero.request())
        let zeroDone = try await zero.waitFor(zeroID.id) { $0.status == .completed }
        #expect(zeroDone.checksum?.isUsable == false)   // an all-zero placeholder was found…
        #expect(zeroDone.checksumVerified == nil)        // …but it's not verified against (no mismatch)
    }

    @Test("Pause preserves progress; resume finishes the file")
    func pauseThenResume() async throws {
        let payload = makePayload(400_000)
        let h = try await Harness(data: payload)
        h.mock.chunkSize = 2048
        h.mock.perChunkDelay = .milliseconds(8)   // slow enough to reliably pause mid-flight
        defer { h.cleanup() }

        let download = await h.manager.add(h.request())
        _ = try await h.waitFor(download.id) { $0.status == .downloading }
        try await Task.sleep(for: .milliseconds(120))   // let several chunks land
        await h.manager.pause(id: download.id)
        let paused = try await h.waitFor(download.id) { $0.status == .paused }
        #expect(paused.downloadedBytes > 0)
        #expect(paused.downloadedBytes < Int64(payload.count))   // genuinely paused mid-transfer

        h.mock.perChunkDelay = .zero   // let it finish quickly now
        await h.manager.resume(id: download.id)
        let done = try await h.waitFor(download.id) { $0.status == .completed }
        #expect(try h.fileData(done) == payload)
    }

    @Test("Resume issued immediately after pause is honored (no stuck-paused race)")
    func pauseThenImmediateResumeCompletes() async throws {
        let payload = makePayload(400_000)
        let h = try await Harness(data: payload)
        h.mock.chunkSize = 2048
        h.mock.perChunkDelay = .milliseconds(6)   // keep it in-flight so pause has work to unwind
        defer { h.cleanup() }

        let download = await h.manager.add(h.request())
        _ = try await h.waitFor(download.id) { $0.status == .downloading }
        try await Task.sleep(for: .milliseconds(60))   // let some bytes land

        // Pause then resume back-to-back, without waiting for `.paused` in between. Because
        // pause() awaits the task's full unwind, the resume's `.queued` can't be clobbered by
        // the task's late `.paused` write. Before that fix this stalls paused forever.
        await h.manager.pause(id: download.id)
        h.mock.perChunkDelay = .zero
        await h.manager.resume(id: download.id)

        let done = try await h.waitFor(download.id, timeout: .seconds(10)) { $0.status == .completed }
        #expect(try h.fileData(done) == payload)
    }

    @Test("State survives a simulated relaunch: a new manager resumes from the same store")
    func resumeAcrossRelaunch() async throws {
        let payload = makePayload(300_000)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cloakdrop-relaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Use one on-disk store shared across two manager "launches".
        let dbPath = directory.appendingPathComponent("state.sqlite").path
        let url = URL(string: "https://example.com/relaunch.bin")!

        // First launch: start a download, pause it with real partial progress.
        let store1 = try GRDBDownloadStore(path: dbPath)
        let mock1 = MockHTTPClient()
        mock1.chunkSize = 2048
        mock1.perChunkDelay = .milliseconds(8)   // keep it in-flight long enough to pause
        mock1.setResource(.init(data: payload, acceptsRanges: true), for: url)
        let manager1 = DownloadManager(store: store1, httpClient: mock1, networkMonitor: AlwaysReachableMonitor())
        try await manager1.start()
        var settings = await manager1.currentSettings()
        settings.minimumSegmentSizeBytes = 1024
        settings.defaultSegmentCount = 4
        await manager1.updateSettings(settings)

        let added = await manager1.add(DownloadRequest(url: url, suggestedFileName: "relaunch.bin", destinationDirectoryPath: directory.path))
        // Let it get in-flight and transfer some bytes, then pause.
        let deadline = ContinuousClock().now + .seconds(10)
        while ContinuousClock().now < deadline {
            if let d = await manager1.snapshot().downloads.first(where: { $0.id == added.id }), d.status == .downloading { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        try await Task.sleep(for: .milliseconds(120))
        await manager1.pause(id: added.id)
        var partialBytes: Int64 = 0
        while ContinuousClock().now < deadline {
            if let d = await manager1.snapshot().downloads.first(where: { $0.id == added.id }), d.status == .paused {
                partialBytes = d.downloadedBytes
                break
            }
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(partialBytes > 0)
        #expect(partialBytes < Int64(payload.count))   // a genuine partial transfer to resume from

        // Second launch: brand-new manager, same store + part file. Resume to completion.
        let store2 = try GRDBDownloadStore(path: dbPath)
        let mock2 = MockHTTPClient()
        mock2.chunkSize = 4096
        mock2.setResource(.init(data: payload, acceptsRanges: true), for: url)
        let manager2 = DownloadManager(store: store2, httpClient: mock2, networkMonitor: AlwaysReachableMonitor())
        try await manager2.start()
        await manager2.resume(id: added.id)

        let resumeDeadline = ContinuousClock().now + .seconds(15)
        var finished: Download?
        while ContinuousClock().now < resumeDeadline {
            if let d = await manager2.snapshot().downloads.first(where: { $0.id == added.id }), d.status == .completed { finished = d; break }
            try await Task.sleep(for: .milliseconds(15))
        }
        let done = try #require(finished)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: done.destinationFilePath))
        #expect(bytes == payload)
    }

    @Test("With resume-on-launch on (default), an interrupted download auto-resumes without an explicit resume")
    func autoResumeOnLaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cloakdrop-autoresume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try GRDBDownloadStore.inMemory()
        try await store.bootstrap()   // create tables before persisting directly (start() also bootstraps, idempotently)
        let url = URL(string: "https://example.com/auto.bin")!
        let payload = makePayload(20_000)
        let mock = MockHTTPClient()
        mock.setResource(.init(data: payload, acceptsRanges: true), for: url)

        // A download persisted as mid-transfer when the app last quit. Default settings resume it.
        var interrupted = Download(url: url, fileName: "auto.bin", destinationDirectoryPath: directory.path)
        interrupted.status = .downloading
        try await store.save(interrupted)

        let manager = DownloadManager(store: store, httpClient: mock, networkMonitor: AlwaysReachableMonitor())
        try await manager.start()   // no explicit resume(): auto-resume-on-launch kicks in

        let deadline = ContinuousClock().now + .seconds(15)
        var finished: Download?
        while ContinuousClock().now < deadline {
            if let d = await manager.snapshot().downloads.first(where: { $0.id == interrupted.id }), d.status == .completed {
                finished = d; break
            }
            try await Task.sleep(for: .milliseconds(15))
        }
        let done = try #require(finished)
        #expect(try Data(contentsOf: URL(fileURLWithPath: done.destinationFilePath)) == payload)
    }

    @Test("With resume-on-launch off, an interrupted download comes back paused and doesn't auto-start")
    func keepPausedOnLaunch() async throws {
        let store = try GRDBDownloadStore.inMemory()
        try await store.bootstrap()   // create tables before persisting directly (start() also bootstraps, idempotently)
        // Persist the preference to keep interrupted downloads paused on launch.
        var settings = EngineSettings.default
        settings.resumeDownloadsOnLaunch = false
        try await store.save(settings: settings)

        // A download that was mid-transfer (persisted `.downloading`) when the app last quit.
        var interrupted = Download(
            url: URL(string: "https://example.com/keep.bin")!,
            fileName: "keep.bin",
            destinationDirectoryPath: FileManager.default.temporaryDirectory.path
        )
        interrupted.status = .downloading
        try await store.save(interrupted)

        // Launch: the manager reconciles persisted state in start(). The mock is never hit because
        // nothing is scheduled.
        let manager = DownloadManager(store: store, httpClient: MockHTTPClient(), networkMonitor: AlwaysReachableMonitor())
        try await manager.start()

        let reloaded = try #require(await manager.snapshot().downloads.first { $0.id == interrupted.id })
        #expect(reloaded.status == .paused)   // came back paused, not queued for auto-resume

        // …and it stays paused rather than being scheduled.
        try await Task.sleep(for: .milliseconds(100))
        let after = try #require(await manager.snapshot().downloads.first { $0.id == interrupted.id })
        #expect(after.status == .paused)
    }

    @Test("Auto-categorization files a completed download into a per-type folder")
    func autoCategorize() async throws {
        let payload = makePayload(20_000)
        let h = try await Harness(data: payload)
        defer { h.cleanup() }

        var settings = await h.manager.currentSettings()
        settings.autoCategorize = true
        await h.manager.updateSettings(settings)

        let download = await h.manager.add(h.request())
        let done = try await h.waitFor(download.id) { $0.status == .completed }

        let expectedFolder = FileCategory.classify(fileName: "payload.bin").displayName
        #expect(done.destinationDirectoryPath.hasSuffix("/" + expectedFolder))
        #expect(FileManager.default.fileExists(atPath: done.destinationFilePath))
        #expect(try h.fileData(done) == payload)
    }

    @Test("Removing a completed download deletes it for good (no resurrection)")
    func removeCompletedNoResurrection() async throws {
        let payload = makePayload(30_000)
        let h = try await Harness(data: payload)
        defer { h.cleanup() }

        let download = await h.manager.add(h.request())
        _ = try await h.waitFor(download.id) { $0.status == .completed }

        await h.manager.remove(id: download.id, deleteFile: true)
        #expect(await h.manager.snapshot().downloads.isEmpty)

        // Give any (incorrectly) detached save a chance to fire, then confirm it stays gone.
        try await Task.sleep(for: .milliseconds(150))
        #expect(try await h.store.allDownloads().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: download.destinationFilePath))
    }

    @Test("Scheduler holds a future download, then promotes it when due")
    func scheduler() async throws {
        let payload = makePayload(10_000)
        let h = try await Harness(data: payload)
        defer { h.cleanup() }

        var request = h.request()
        request.scheduledStart = Date().addingTimeInterval(3600)   // an hour out
        let download = await h.manager.add(request)

        let scheduled = try await h.waitFor(download.id) { $0.status == .scheduled }
        #expect(scheduled.status == .scheduled)

        // Simulate time passing.
        await h.manager.promoteScheduled(asOf: Date().addingTimeInterval(7200))
        let done = try await h.waitFor(download.id) { $0.status == .completed }
        #expect(try h.fileData(done) == payload)
    }

    @Test("Auth credentials and referrer/cookies reach the HTTP layer")
    func authAndHeadersThreaded() async throws {
        let payload = makePayload(40_000)
        let h = try await Harness(data: payload)
        defer { h.cleanup() }
        // No sibling-checksum requests, so `lastRequest` is deterministically the download's own.
        var settings = await h.manager.currentSettings()
        settings.autoDiscoverChecksums = false
        await h.manager.updateSettings(settings)

        var request = h.request()
        request.username = "alice"
        request.password = "s3cret"
        request.referrer = "https://example.com/page"
        request.cookies = "session=abc"
        let download = await h.manager.add(request)
        _ = try await h.waitFor(download.id) { $0.status == .completed }

        let last = h.mock.lastRequest
        #expect(last?.username == "alice")
        #expect(last?.password == "s3cret")
        #expect(last?.headers["Referer"] == "https://example.com/page")
        #expect(last?.headers["Cookie"] == "session=abc")
    }

    @Test("Basic authorization header is well-formed")
    func basicAuthEncoding() {
        let value = URLSessionHTTPClient.basicAuthorizationValue(user: "alice", password: "s3cret")
        #expect(value == "Basic " + Data("alice:s3cret".utf8).base64EncodedString())
    }

    @Test("A recurring download schedules its next occurrence on completion")
    func recurringReschedules() async throws {
        let payload = makePayload(20_000)
        let h = try await Harness(data: payload)
        defer { h.cleanup() }

        var request = h.request()
        request.recurrence = .daily
        let download = await h.manager.add(request)
        _ = try await h.waitFor(download.id) { $0.status == .completed }

        // The completed original should be joined by a freshly scheduled copy for the next run.
        var all = await h.manager.snapshot().downloads
        let deadline = ContinuousClock().now + .seconds(5)
        while ContinuousClock().now < deadline {
            all = await h.manager.snapshot().downloads
            if all.contains(where: { $0.status == .scheduled && $0.recurrence == .daily }) { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(all.count == 2)
        let next = all.first { $0.status == .scheduled }
        #expect(next?.id != download.id)
        #expect(next?.scheduledStart != nil)
        #expect(next?.recurrence == .daily)
    }

    @Test("Completing the last download emits allDownloadsCompleted")
    func allDownloadsCompletedSignal() async throws {
        let payload = makePayload(20_000)
        let h = try await Harness(data: payload)
        defer { h.cleanup() }

        let flag = SignalFlag()
        let collector = Task {
            for await event in h.manager.events where event.isAllCompleted { await flag.mark() }
        }
        defer { collector.cancel() }

        let download = await h.manager.add(h.request())
        _ = try await h.waitFor(download.id) { $0.status == .completed }
        try await Task.sleep(for: .milliseconds(250))
        #expect(await flag.value)
    }
}

/// Test helper: a thread-safe one-shot flag for observing an engine event.
private actor SignalFlag {
    private(set) var value = false
    func mark() { value = true }
}

private extension EngineEvent {
    var isAllCompleted: Bool {
        if case .allDownloadsCompleted = self { return true }
        return false
    }
}

import CryptoKit
private func sha256Hex(_ data: Data) throws -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
