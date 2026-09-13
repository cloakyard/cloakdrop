import SwiftUI
import WebKit

/// The browser's `WKWebView` subclass. Exists for the AppKit-only affordances: the tab-bar "+"
/// (`newWindowForTab` arrives via the responder chain) — and as the seam for future context-menu
/// surgery if WebKit's own "Download Linked File" items ever need rerouting (today they surface
/// through `WKNavigationDelegate.navigationAction(_:didBecome:)`, which we already take over).
final class SnifferWebView: WKWebView {
    var onNewTab: (() -> Void)?
    var onWindowClose: (() -> Void)?
    private var didStopForClosure = false

    override func newWindowForTab(_ sender: Any?) {
        onNewTab?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Keep observing through a temporary unmount; window closure can finish after SwiftUI
        // detaches the content. Moving to another window replaces the old observation.
        guard let window else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: window
        )
    }

    @objc private func windowWillClose(_ notification: Notification) {
        onWindowClose?()
        stopForWindowClose()
    }

    /// Closing a window is terminal; hiding it or switching native tabs is not. `stopLoading`
    /// alone leaves loaded players, iframe audio and page timers alive in a retained web view.
    func stopForWindowClose() {
        guard !didStopForClosure else { return }
        didStopForClosure = true
        onWindowClose = nil
        onNewTab = nil
        stopLoading()
        setAllMediaPlaybackSuspended(true, completionHandler: nil)
        closeAllMediaPresentations(completionHandler: nil)
        navigationDelegate = nil
        uiDelegate = nil
        configuration.userContentController.removeAllUserScripts()
        loadHTMLString("", baseURL: nil)
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
