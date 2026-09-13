import AppKit
import WebKit

/// Compile with App/Features/Browser/BrowserWebView.swift. Uses an ephemeral WebKit store and
/// generated silent audio; no app catalog, browsing data, network, or external media is involved.
@main
struct BrowserPlaybackRegression {
    @MainActor
    static func main() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = SnifferWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 180), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Browser playback regression"
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        var closeCount = 0
        webView.onWindowClose = { closeCount += 1 }
        let audio = silentWAV().base64EncodedString()
        webView.loadHTMLString("""
        <iframe srcdoc="<audio id='player' autoplay loop src='data:audio/wav;base64,\(audio)'></audio>
        <script>setInterval(() => player.play().catch(() => {}), 100)</script>"></iframe>
        """, baseURL: nil)

        try await waitUntil { await webView.requestMediaPlaybackState() == .playing }
        window.orderOut(nil)
        precondition(closeCount == 0, "Hiding or switching away must not tear down the session")
        window.makeKeyAndOrderFront(nil)
        let destination = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        destination.isReleasedWhenClosed = false
        window.contentView = nil
        destination.contentView = webView
        destination.makeKeyAndOrderFront(nil)
        window.close()
        precondition(closeCount == 0, "After moving tabs, closing the old window must not stop this player")
        try await waitUntil { await webView.requestMediaPlaybackState() == .playing }
        destination.contentView = nil
        destination.close()
        precondition(closeCount == 1, "The native close notification must run cleanup once")
        // Deliberately retain WKWebView, as SwiftUI can do after its window closes.
        try await waitUntil {
            let state = await webView.requestMediaPlaybackState()
            return state != .playing && webView.url?.absoluteString == "about:blank"
        }
        webView.stopForWindowClose()
        try await Task.sleep(for: .milliseconds(400))
        let state = await webView.requestMediaPlaybackState()
        precondition(state != .playing, "Page timers must not restart playback after closure")
        let mediaCount = try await webView.evaluateJavaScript("document.querySelectorAll('audio,video,iframe').length") as? Int
        precondition(mediaCount == 0, "The closed page must be unloaded")
        precondition(closeCount == 1)
        print("Browser playback regression passed: iframe playing → window closed → page unloaded; no restart")
    }

    @MainActor
    private static func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw Failure.timedOut }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func silentWAV() -> Data {
        var result = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { result.append(contentsOf: $0) }
        }
        append(UInt32(16_036))
        result.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(8_000)); append(UInt32(16_000))
        append(UInt16(2)); append(UInt16(16))
        result.append(contentsOf: "data".utf8)
        append(UInt32(16_000))
        result.append(Data(count: 16_000))
        return result
    }

    private enum Failure: Error { case timedOut }
}

/// Satisfies the unused SwiftUI hosting wrapper while compiling the production web view alone.
@MainActor
final class BrowserSession {
    var webView: SnifferWebView!
}
