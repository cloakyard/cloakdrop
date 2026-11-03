import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadPersistence
@testable import DownloadEngine

@Suite("Playlist import")
struct PlaylistImportTests {
    @Test("Multiple videos embedded on one page retain their distinct media URLs")
    func embeddedVideoEntries() throws {
        let json = #"""
        {"title":"Lessons","webpage_url":"https://example.com/lessons","entries":[
          {"title":"One","webpage_url":"https://example.com/lessons","url":"https://example.com/one.mp4"},
          {"title":"Two","webpage_url":"https://example.com/lessons","url":"https://example.com/two.mp4"}
        ]}
        """#
        let playlist = try MediaPlaylist.parse(json: Data(json.utf8))
        #expect(playlist.entries.compactMap(\.pageURL).map(\.lastPathComponent) == ["one.mp4", "two.mp4"])
    }

    @Test("Enumeration is bounded, metadata-only, ordered and deduplicated")
    func enumeration() async throws {
        var entries: [[String: Any]] = (1...102).map {
            ["title": "Item \($0)", "url": "https://example.com/watch/\($0)"]
        }
        entries[1]["url"] = entries[0]["url"]
        entries[2]["url"] = "file:///private/data"
        let data = try JSONSerialization.data(withJSONObject: ["title": "A playlist", "entries": entries])
        let runner = MockProcessRunner(stdout: data)
        let extractor = YtDlpExtractor(executableURL: URL(fileURLWithPath: "/unused"), runner: runner)
        let url = URL(string: "https://example.com/playlist")!
        let result = try await extractor.playlist(pageURL: url)
        #expect(result.entries.count == 100)
        #expect(result.hasMore)
        #expect(result.entries[0].index == 1)
        #expect(result.entries[1].pageURL == nil)
        #expect(result.entries[2].pageURL == nil)
        #expect(runner.lastArguments.contains("--simulate"))
        #expect(runner.lastArguments.contains("--flat-playlist"))
        #expect(runner.lastArguments.contains("101"))
        #expect(Array(runner.lastArguments.suffix(2)) == ["--", url.absoluteString])
    }

    @Test("A plain video or malformed playlist does not pretend to be an imported collection")
    func rejectsNonPlaylists() throws {
        #expect(throws: (any Error).self) { try MediaPlaylist.parse(json: Data("{}".utf8)) }
        #expect(throws: (any Error).self) { try MediaPlaylist.parse(json: Data("{\"entries\": []}".utf8)) }
    }

    @Test("One quality preference selects each item's eligible video/audio and never silently upscales")
    func qualitySelection() async throws {
        let extractor = WorkflowMediaExtractor()
        let resolver = PageMediaResolver(extractor: extractor, httpClient: MockHTTPClient())
        let url = URL(string: "https://example.com/watch/one")!
        let low = try await resolver.resolve(url: url, selection: .init(quality: .hd720, outputFormat: .original))
        #expect(low.plan.resolution?.height == 360)
        let high = try await resolver.resolve(url: url, selection: .init(quality: .hd1080, outputFormat: .original))
        #expect(high.plan.resolution?.height == 1080)
        #expect(high.plan.audioSegments?.count == 1)
        let audio = try await resolver.resolve(url: url, selection: .init(quality: .audioOnly))
        #expect(audio.plan.outputFormat == .originalAudio)
        #expect(audio.plan.segments.first?.url.absoluteString == "https://example.com/audio.m4a")
    }

    @Test("Queued pages persist without extraction, resolve on start after relaunch, and skip existing URLs")
    func deferredExtractionAcrossRelaunch() async throws {
        let h = try await DownloadWorkflowHarness()
        defer { h.cleanup() }
        let extractor = WorkflowMediaExtractor()
        let manager = DownloadManager(store: h.store, httpClient: h.mock, networkMonitor: AlwaysReachableMonitor(),
                                      remuxer: PassthroughRemuxer(), mediaExtractor: extractor)
        try await manager.start()
        let playlist = MediaPlaylist(title: "Lessons", entries: [
            .init(index: 1, title: "First", pageURL: URL(string: "https://example.com/watch/one")),
            .init(index: 2, title: "Second", pageURL: URL(string: "https://example.com/watch/two"))
        ])
        let downloads = try await manager.addPlaylist(playlist, selectedIDs: [1, 2],
                                                      selection: .init(quality: .hd720, outputFormat: .original),
                                                      directory: h.directory, bookmark: nil, startImmediately: false)
        #expect(downloads.count == 2)
        #expect(downloads[0].fileName.hasPrefix("001 - "))
        #expect(downloads[1].fileName.hasPrefix("002 - "))
        #expect(await extractor.calls == 0)
        #expect(downloads.allSatisfy { $0.isMedia && $0.mediaPlan == nil })
        let skipped = try await manager.addPlaylist(playlist, selectedIDs: [1, 2], selection: .init(),
                                                    directory: h.directory, bookmark: nil)
        #expect(skipped.isEmpty)
        h.mock.setResource(.init(data: h.payload), for: URL(string: "https://example.com/low.mp4")!)
        let reloaded = DownloadManager(store: h.store, httpClient: h.mock, networkMonitor: AlwaysReachableMonitor(),
                                       remuxer: PassthroughRemuxer(), mediaExtractor: extractor)
        try await reloaded.start()
        await reloaded.resumeAll()
        for download in downloads {
            let done = try await h.waitFor(download.id, manager: reloaded)
            #expect(done.mediaPlan != nil)
            #expect(try Data(contentsOf: URL(fileURLWithPath: done.destinationFilePath)) == h.payload)
        }
        #expect(await extractor.calls == 2)
    }

    @Test("An unavailable playlist item has an actionable error and does not block other items")
    func unavailableItemIsIsolated() async throws {
        let h = try await DownloadWorkflowHarness()
        defer { h.cleanup() }
        let manager = DownloadManager(store: h.store, httpClient: h.mock, networkMonitor: AlwaysReachableMonitor(),
                                      remuxer: PassthroughRemuxer(), mediaExtractor: WorkflowMediaExtractor())
        try await manager.start()
        h.mock.setResource(.init(data: h.payload), for: URL(string: "https://example.com/low.mp4")!)
        let playlist = MediaPlaylist(title: "Lessons", entries: [
            .init(index: 1, title: "Unavailable", pageURL: URL(string: "https://example.com/watch/unavailable")),
            .init(index: 2, title: "Available", pageURL: URL(string: "https://example.com/watch/one"))
        ])
        let added = try await manager.addPlaylist(playlist, selectedIDs: [1, 2],
                                                  selection: .init(quality: .hd720, outputFormat: .original),
                                                  directory: h.directory, bookmark: nil)
        let failed = try await h.waitFor(added[0].id, manager: manager) {
            if case .failed = $0.status { return true }; return false
        }
        if case .failed(let reason) = failed.status {
            #expect(reason.contains("different quality or format"))
            #expect(!reason.contains("MediaExtractionError"))
        }
        let done = try await h.waitFor(added[1].id, manager: manager)
        #expect(try Data(contentsOf: URL(fileURLWithPath: done.destinationFilePath)) == h.payload)
        #expect(!FileManager.default.fileExists(atPath: failed.destinationFilePath))
    }
}

private actor WorkflowMediaExtractor: MediaExtractor {
    var calls = 0
    func version() async -> String? { "test" }
    func extract(pageURL: URL, cookies: ExtractionCookies?, userAgent: String?) async throws -> ExtractedMedia {
        calls += 1
        if pageURL.lastPathComponent == "unavailable" { throw MediaExtractionError.noGrabbableFormats }
        return try ExtractedMedia.parse(json: Data(#"""
        {"title":"Example","formats":[
          {"format_id":"low","url":"https://example.com/low.mp4","ext":"mp4",
           "vcodec":"avc1.42001E","acodec":"mp4a.40.2","width":640,"height":360},
          {"format_id":"high","url":"https://example.com/high.mp4","ext":"mp4",
           "vcodec":"avc1.640028","acodec":"none","width":1920,"height":1080},
          {"format_id":"audio","url":"https://example.com/audio.m4a","ext":"m4a",
           "vcodec":"none","acodec":"mp4a.40.2","abr":128}
        ]}
        """#.utf8))
    }
}
