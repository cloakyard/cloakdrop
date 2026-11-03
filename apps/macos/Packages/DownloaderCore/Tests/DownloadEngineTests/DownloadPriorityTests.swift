import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadPersistence
@testable import DownloadEngine

@Suite("Finish this first")
struct DownloadPriorityTests {
    @Test("Competing transfers wait, user pauses stay paused, and work resumes on completion")
    func prioritizesAndRestores() async throws {
        let h = try await DownloadWorkflowHarness()
        defer { h.cleanup() }
        h.mock.chunkSize = 1024
        h.mock.perChunkDelay = .milliseconds(8)
        h.mock.setResource(.init(data: h.payload), for: h.source)
        let peer = await h.manager.add(request(h, name: "peer.bin"))
        let manual = await h.manager.add(request(h, name: "manual.bin", start: false))
        let target = await h.manager.add(request(h, name: "urgent.bin", start: false))
        try await h.manager.finishFirst(id: target.id)
        let snapshot = await h.manager.snapshot()
        #expect(snapshot.settings.downloadPriority?.downloadID == target.id)
        #expect(snapshot.downloads.first { $0.id == peer.id }?.status == .queued)
        #expect(snapshot.downloads.first { $0.id == manual.id }?.status == .paused)
        _ = try await h.waitFor(target.id)
        _ = try await h.waitFor(peer.id)
        #expect(await h.manager.currentSettings().downloadPriority == nil)
        #expect(await h.manager.snapshot().downloads.first { $0.id == manual.id }?.status == .paused)
    }

    @Test("A manually paused held item stays paused after priority ends")
    func pauseHeldItem() async throws {
        let h = try await DownloadWorkflowHarness()
        defer { h.cleanup() }
        h.mock.chunkSize = 1024
        h.mock.perChunkDelay = .milliseconds(8)
        h.mock.setResource(.init(data: h.payload), for: h.source)
        let peer = await h.manager.add(request(h, name: "peer.bin"))
        let target = await h.manager.add(request(h, name: "urgent.bin", start: false))
        try await h.manager.finishFirst(id: target.id)
        await h.manager.pause(id: peer.id)
        await h.manager.stopFinishingFirst()
        #expect(await h.manager.snapshot().downloads.first { $0.id == peer.id }?.status == .paused)
        await h.manager.pauseAll()
    }

    @Test("Failure releases competing queues")
    func targetFailureRestoresPeers() async throws {
        let h = try await DownloadWorkflowHarness()
        defer { h.cleanup() }
        h.mock.setResource(.init(data: h.payload), for: h.source)
        let peer = await h.manager.add(request(h, name: "peer.bin", start: false))
        var bad = request(h, name: "missing.bin", start: false)
        bad.url = h.replacement
        let target = await h.manager.add(bad)
        try await h.manager.finishFirst(id: target.id)
        await h.manager.resume(id: peer.id)
        _ = try await h.waitFor(target.id) { if case .failed = $0.status { return true }; return false }
        _ = try await h.waitFor(peer.id)
        #expect(await h.manager.currentSettings().downloadPriority == nil)
    }

    @Test("Relaunch restores a held worker but respects resume-on-launch off")
    func relaunchPriority() async throws {
        for resume in [true, false] {
            let h = try await DownloadWorkflowHarness()
            defer { h.cleanup() }
            var target = Download(url: h.source, fileName: "urgent.bin", destinationDirectoryPath: h.directory.path)
            target.status = .downloading
            let peer = Download(url: h.source, fileName: "peer.bin", destinationDirectoryPath: h.directory.path, status: .paused)
            let manual = Download(url: h.source, fileName: "manual.bin", destinationDirectoryPath: h.directory.path, status: .paused)
            try await h.store.save(target)
            try await h.store.save(peer)
            try await h.store.save(manual)
            var settings = await h.manager.currentSettings()
            settings.resumeDownloadsOnLaunch = resume
            settings.downloadPriority = DownloadPriority(downloadID: target.id, heldDownloadIDs: [peer.id])
            try await h.store.save(settings: settings)
            h.mock.setResource(.init(data: h.payload), for: h.source)
            let reloaded = DownloadManager(store: h.store, httpClient: h.mock, networkMonitor: AlwaysReachableMonitor())
            try await reloaded.start()
            if resume {
                _ = try await h.waitFor(target.id, manager: reloaded)
                _ = try await h.waitFor(peer.id, manager: reloaded)
            } else {
                #expect(await reloaded.snapshot().downloads.allSatisfy { $0.status == .paused })
                #expect(await reloaded.currentSettings().downloadPriority == nil)
            }
            #expect(await reloaded.snapshot().downloads.first { $0.id == manual.id }?.status == .paused)
        }
    }

    private func request(_ h: DownloadWorkflowHarness, name: String, start: Bool = true) -> DownloadRequest {
        DownloadRequest(url: h.source, suggestedFileName: name, destinationDirectoryPath: h.directory.path, startImmediately: start)
    }
}
