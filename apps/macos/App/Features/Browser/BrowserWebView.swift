import SwiftUI
import WebKit

/// The browser's `WKWebView` subclass. Exists for the AppKit-only affordances: the tab-bar "+"
/// (`newWindowForTab` arrives via the responder chain) — and as the seam for future context-menu
/// surgery if WebKit's own "Download Linked File" items ever need rerouting (today they surface
/// through `WKNavigationDelegate.navigationAction(_:didBecome:)`, which we already take over).
final class SnifferWebView: WKWebView {
    var onNewTab: (() -> Void)?

    override func newWindowForTab(_ sender: Any?) {
        onNewTab?()
    }
}

/// Hosts the session's web view in SwiftUI. The view is created and owned by `BrowserSession`
/// (state and delegates outlive SwiftUI's view churn); this wrapper only mounts it.
struct BrowserWebViewHost: NSViewRepresentable {
    let session: BrowserSession

    func makeNSView(context: Context) -> SnifferWebView { session.webView }
    func updateNSView(_ nsView: SnifferWebView, context: Context) {}
}

/// Reaches the hosting `NSWindow` to opt browser windows into native tabbing (⌘-drag windows into
/// tabs, Window ▸ Merge All Windows, the tab bar's "+").
struct BrowserWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = NSView()
        DispatchQueue.main.async { [weak probe] in
            guard let window = probe?.window else { return }
            window.tabbingMode = .preferred
            window.tabbingIdentifier = "cloakdrop.browser"
        }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
