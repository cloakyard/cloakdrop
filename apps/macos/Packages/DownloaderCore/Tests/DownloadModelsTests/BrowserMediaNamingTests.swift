import Foundation
import Testing
@testable import DownloadModels

@Suite("Browser media naming")
struct BrowserMediaNamingTests {
    private let endpoint = "https://cdn.example/media?id=42"

    @Test("Extensionless direct media uses the containing page title and response container")
    func endpointTitle() {
        let item = SniffedItem(url: endpoint, type: .video)
        #expect(item.downloadFileName(pageTitle: "Episode 2.5", mimeType: "video/mp4; charset=binary") == "Episode 2.5.mp4")
        #expect(item.downloadFileName(pageTitle: "Episode 2.5") == "Episode 2.5")
        #expect(item.downloadFileName(pageTitle: "", mimeType: "video/webm") == "media.webm")
    }

    @Test("Attachment names, containers, and ordinary files remain meaningful")
    func explicitNames() {
        let attachment = SniffedItem(url: endpoint, type: .video, filename: "Original.mov")
        #expect(attachment.downloadFileName(pageTitle: "Page", mimeType: "video/mp4") == "Original.mov")
        let video = SniffedItem(url: "https://cdn.example/movie.webm", type: .video)
        #expect(video.downloadFileName(pageTitle: "Page") == "Page.webm")
        let audio = SniffedItem(url: endpoint, type: .audio)
        #expect(audio.downloadFileName(pageTitle: "Recording", mimeType: "audio/mp4") == "Recording.m4a")
        let stream = SniffedItem(url: "https://cdn.example/master.m3u8", type: .stream)
        #expect(stream.downloadFileName(pageTitle: "Episode 2.5") == "Episode 2.5")
        let file = SniffedItem(url: "https://cdn.example/app.zip", type: .file)
        #expect(file.downloadFileName(pageTitle: "Download portal") == nil)
    }

    @Test("Page text is sanitized before it becomes a filename")
    func sanitizeTitle() {
        let item = SniffedItem(url: endpoint, type: .video)
        #expect(item.downloadFileName(pageTitle: "A/B:C\\D\n", mimeType: "video/mp4") == "A_B_C_D.mp4")
    }

    @Test("Long Unicode titles leave room for the extension and staging suffix")
    func boundedTitle() throws {
        let item = SniffedItem(url: endpoint, type: .video)
        let name = try #require(item.downloadFileName(pageTitle: String(repeating: "映像", count: 150), mimeType: "video/mp4"))
        #expect(name.utf8.count <= 240)
        #expect(name.hasSuffix(".mp4"))
        #expect((name + " (9999).cdpart").utf8.count <= 255)
    }

    @Test("An iframe supplies media while the top frame supplies its title")
    func embeddedPlayer() throws {
        var state = PageMediaState(pageURL: "https://pages.example/watch/42")
        state.apply(SniffEnvelope(frameURL: state.pageURL, isTopFrame: true, events: [
            SniffEvent(kind: .page, title: "The Parent Title")
        ]))
        state.apply(SniffEnvelope(frameURL: "https://embed.example/player", isTopFrame: false, events: [
            SniffEvent(kind: .page, title: "Player"),
            SniffEvent(kind: .element, url: endpoint, tag: "video")
        ]))
        let item = try #require(state.candidates.first)
        #expect(item.downloadFileName(pageTitle: state.pageTitle, mimeType: "video/mp4") == "The Parent Title.mp4")
    }

    @Test("Later resource sightings retain an earlier attachment filename")
    func retainsResponseName() throws {
        var state = PageMediaState(pageURL: "https://pages.example/watch/42")
        let url = "https://cdn.example/movie.mp4"
        state.apply(SniffEnvelope(frameURL: state.pageURL, isTopFrame: true, events: [
            SniffEvent(kind: .response, url: url, contentType: "video/mp4",
                       contentDisposition: "attachment; filename=Original.mp4"),
            SniffEvent(kind: .element, url: url, tag: "video"),
            SniffEvent(kind: .resource, url: url)
        ]))
        let item = try #require(state.candidates.first)
        #expect(item.downloadFileName(pageTitle: "Page") == "Original.mp4")
    }
}
