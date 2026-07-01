import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadPersistence
@testable import DownloadEngine

@Suite("Link intelligence (pre-flight probe → LinkPreview)")
struct LinkInspectorTests {

    private let settings = EngineSettings(
        defaultSegmentCount: 8,
        maxSegmentCount: 16,
        minimumSegmentSizeBytes: 100_000
    )

    // MARK: Segment-count estimate (mirrors the real transfer's planning)

    @Test("A resumable, splittable resource estimates multiple connections")
    func plannedSegmentsForLargeResumable() {
        // 800 KB with a 100 KB minimum → capacity 8, requested min(16, 8) = 8.
        let count = LinkInspector.plannedSegmentCount(totalBytes: 800_000, acceptsRanges: true, settings: settings)
        #expect(count == 8)
    }

    @Test("A non-resumable resource estimates a single connection")
    func plannedSegmentsForNonResumable() {
        #expect(LinkInspector.plannedSegmentCount(totalBytes: 800_000, acceptsRanges: false, settings: settings) == 1)
    }

    @Test("A resource too small to split estimates a single connection")
    func plannedSegmentsForTinyResource() {
        // Below minimum × 2 → not worth splitting.
        #expect(LinkInspector.plannedSegmentCount(totalBytes: 150_000, acceptsRanges: true, settings: settings) == 1)
    }

    @Test("An unknown size estimates a single connection")
    func plannedSegmentsForUnknownSize() {
        #expect(LinkInspector.plannedSegmentCount(totalBytes: nil, acceptsRanges: true, settings: settings) == 1)
    }

    // MARK: File-name derivation

    @Test("A server-suggested file name wins, reduced to its last path component")
    func fileNameFromSuggestion() {
        let url = URL(string: "https://host.example/dl?id=42")!
        #expect(LinkInspector.fileName(from: "installer.dmg", finalURL: url) == "installer.dmg")
        #expect(LinkInspector.fileName(from: "/packages/installer.dmg", finalURL: url) == "installer.dmg")
    }

    @Test("With no usable suggestion, the file name comes from the (redirected) URL, then host")
    func fileNameFromURL() {
        #expect(LinkInspector.fileName(from: nil, finalURL: URL(string: "https://host.example/files/app.zip")!) == "app.zip")
        #expect(LinkInspector.fileName(from: "   ", finalURL: URL(string: "https://host.example/files/app.zip")!) == "app.zip")
        #expect(LinkInspector.fileName(from: nil, finalURL: URL(string: "https://host.example")!) == "host.example")
    }

    // MARK: inspect() over the mock client

    @Test("Inspecting a resumable resource reports size, type, resumability, and the segment estimate")
    func inspectResumable() async throws {
        let url = URL(string: "https://example.com/app")!
        let mock = MockHTTPClient()
        mock.setResource(
            .init(data: Data(count: 800_000), acceptsRanges: true, suggestedFilename: "app.dmg",
                  etag: "\"v1\"", mimeType: "application/x-apple-diskimage"),
            for: url
        )

        let preview = try await LinkInspector(httpClient: mock).inspect(url: url, settings: settings)

        #expect(preview.requestedURL == url)
        #expect(preview.finalURL == url)
        #expect(preview.wasRedirected == false)
        #expect(preview.suggestedFileName == "app.dmg")
        #expect(preview.totalBytes == 800_000)
        #expect(preview.isResumable == true)
        #expect(preview.plannedSegmentCount == 8)
        #expect(preview.isMultiSegment == true)
        #expect(preview.mimeType == "application/x-apple-diskimage")
        #expect(preview.etag == "\"v1\"")
        #expect(preview.category == .archive)   // .dmg → archive
    }

    @Test("Inspecting a range-less server reports non-resumable and a single connection")
    func inspectNonResumable() async throws {
        let url = URL(string: "https://example.com/stream.bin")!
        let mock = MockHTTPClient()
        mock.setResource(.init(data: Data(count: 800_000), acceptsRanges: false), for: url)

        let preview = try await LinkInspector(httpClient: mock).inspect(url: url, settings: settings)
        #expect(preview.isResumable == false)
        #expect(preview.plannedSegmentCount == 1)
        #expect(preview.isMultiSegment == false)
    }

    @Test("A redirect is reported: the final URL differs and names the file when the server didn't")
    func inspectRedirect() async throws {
        let requested = URL(string: "https://cdn.example/download?id=9")!
        let landed = URL(string: "https://mirror.example/files/tool.pkg")!
        let mock = MockHTTPClient()
        mock.setResource(.init(data: Data(count: 500_000), acceptsRanges: true, finalURL: landed), for: requested)

        let preview = try await LinkInspector(httpClient: mock).inspect(url: requested, settings: settings)
        #expect(preview.requestedURL == requested)
        #expect(preview.finalURL == landed)
        #expect(preview.wasRedirected == true)
        #expect(preview.suggestedFileName == "tool.pkg")   // derived from the landing URL
        #expect(preview.category == .program)              // .pkg → program
    }

    @Test("Inspecting an unreachable resource throws (a preview is best-effort, not a guess)")
    func inspectFailureThrows() async throws {
        let mock = MockHTTPClient()   // no resources registered → probe 404s
        await #expect(throws: DownloadError.self) {
            _ = try await LinkInspector(httpClient: mock).inspect(url: URL(string: "https://example.com/missing")!, settings: settings)
        }
    }

    // MARK: Manager-level preview() intent

    @Test("DownloadManager.preview returns a LinkPreview for a reachable URL, nil for an unreachable one")
    func managerPreview() async throws {
        let store = try GRDBDownloadStore.inMemory()
        let url = URL(string: "https://example.com/payload.iso")!
        let mock = MockHTTPClient()
        mock.setResource(
            .init(data: Data(count: 800_000), acceptsRanges: true, suggestedFilename: "payload.iso", etag: "\"abc\""),
            for: url
        )
        let manager = DownloadManager(store: store, httpClient: mock, networkMonitor: AlwaysReachableMonitor())
        try await manager.start()
        var settings = await manager.currentSettings()
        settings.minimumSegmentSizeBytes = 100_000
        settings.defaultSegmentCount = 8
        await manager.updateSettings(settings)

        let preview = try #require(await manager.preview(url: url))
        #expect(preview.suggestedFileName == "payload.iso")
        #expect(preview.totalBytes == 800_000)
        #expect(preview.isResumable == true)
        #expect(preview.plannedSegmentCount == 8)
        #expect(preview.etag == "\"abc\"")

        #expect(await manager.preview(url: URL(string: "https://example.com/nope")!) == nil)
    }

    @Test("preview folds referrer and cookies into the probe request, mirroring add()")
    func previewFoldsCaptureHeaders() async throws {
        let store = try GRDBDownloadStore.inMemory()
        let url = URL(string: "https://example.com/protected.zip")!
        let mock = MockHTTPClient()
        mock.setResource(.init(data: Data(count: 300_000), acceptsRanges: true), for: url)
        let manager = DownloadManager(store: store, httpClient: mock, networkMonitor: AlwaysReachableMonitor())
        try await manager.start()

        _ = await manager.preview(url: url, referrer: "https://example.com/page", cookies: "session=xyz")
        #expect(mock.lastRequest?.headers["Referer"] == "https://example.com/page")
        #expect(mock.lastRequest?.headers["Cookie"] == "session=xyz")
    }
}
