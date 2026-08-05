import SwiftUI
import WebKit
import DownloadModels

/// One browser window's state and behavior: owns the `WKWebView`, mirrors its observable state
/// for SwiftUI, aggregates sniffed media, and hands downloads/extractions to the app through
/// `BrowserCaptureSink`. All four WebKit delegate conformances live in
/// `BrowserSession+Delegates.swift`.
@Observable
@MainActor
final class BrowserSession: NSObject {
    static let runnerAddress = "cloakdrop://runner"

    private(set) var webView: SnifferWebView!

    // Chrome state (mirrored from the web view).
    var urlText = ""
    private(set) var currentURL: URL?
    private(set) var pageTitle = ""
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isSecure = false
    private(set) var loadError: BrowserLoadError?
    private(set) var isRunnerPresented = false
    /// The current page's favicon, shown next to the address bar in place of the window title.
    private(set) var favicon: NSImage?

    // Sniffing.
    private(set) var media = PageMediaState()
    /// The deduped, ranked shelf items — cached because `PageMediaState.candidates` runs the full
    /// dedupe cascade (quadratic over up to 60 records): recomputed only when a sniff envelope or
    /// navigation changes the state, not on every toolbar render (progress KVO, address-bar
    /// keystrokes, favicon) that reads the badge.
    private(set) var shelfItems: [SniffedItem] = []

    // Interactions awaiting the user.
    var dialog: BrowserDialog?
    var authRequest: BrowserAuthRequest?

    /// Set when this window should close itself (a page-opened popup whose only purpose turned
    /// out to be a download we took over).
    private(set) var shouldClose = false
    /// Bumped by the ⌘L command; the view responds by focusing the URL field.
    private(set) var urlBarFocusToken = 0
    /// The view keeps this current so background navigation never stomps on the user's typing.
    var isEditingURLBar = false
    /// Whether non-URL address-bar text becomes a search (mirrors the setting).
    var searchEnabled = true
    /// Which engine an address-bar search uses (mirrors the setting).
    var searchEngine: SearchEngine = .duckDuckGo
    /// Whether ad/tracker blocking is on (mirrors the setting). Gates the compiled content-rule list
    /// on this web view and ad-host popup rejection in the UI delegate.
    private(set) var adBlockEnabled = false

    weak var sink: (any BrowserCaptureSink)?
    /// Opens a sibling browser window (wired to `openWindow` by the view).
    var onOpenWindow: ((URL?) -> Void)?

    /// True for windows the *page* opened (`window.open`/`target=_blank`) — they may auto-close
    /// if their first response becomes a download.
    let openedByPage: Bool
    private(set) var hasCommittedNavigation = false

    /// The effective user agent (WebKit-composed) — captured once and attached to every handoff
    /// so the engine fetches as the same client the site saw.
    private(set) var userAgent: String?

    private var observations: [NSKeyValueObservation] = []
    private var lastCrashRecovery: Date?
    var popupTimestamps: [Date] = []
    /// One page may emit the same WebKit download through more than one delegate callback, and a
    /// fast double-click can beat the row's visual checkmark. Keep a per-page handoff gate so one
    /// grab gesture can enqueue only one engine request.
    private var handedOffKeys: Set<String> = []
    private static let messageHandlerName = "mediaSniffer"

    init(openedByPage: Bool = false) {
        self.openedByPage = openedByPage
        super.init()
        let configuration = BrowserStore.shared.makeConfiguration()
        configuration.userContentController.add(
            WeakScriptMessageHandler(self), contentWorld: .page, name: Self.messageHandlerName
        )
        webView = SnifferWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.onNewTab = { [weak self] in self?.onOpenWindow?(nil) }
        observeWebView()
    }

    private func observeWebView() {
        // WebKit KVO fires on the main thread; each handler hops the isolation boundary explicitly.
        observations = [
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.pageTitle = view.title ?? "" }
            },
            webView.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.urlDidChange(view.url) }
            },
            webView.observe(\.hasOnlySecureContent, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.refreshSecurity(hasOnlySecureContent: view.hasOnlySecureContent) }
            }
        ]
    }

    private func urlDidChange(_ url: URL?) {
        currentURL = url
        refreshSecurity(hasOnlySecureContent: webView.hasOnlySecureContent)
        if let url, !isEditingURLBar { urlText = url.absoluteString }
    }

    private func refreshSecurity(hasOnlySecureContent: Bool) {
        isSecure = currentURL?.scheme?.lowercased() == "https" && hasOnlySecureContent
    }

    // MARK: - Navigation intents

    /// Load whatever the user typed: a URL as-is, a bare host with `https://` prefixed, or a
    /// search (on the chosen engine) for anything that doesn't look like an address.
    func commitURLBar() {
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if Self.isRunnerAddress(text) {
            webView.stopLoading()
            loadError = nil
            isRunnerPresented = true
            urlText = Self.runnerAddress
            return
        }
        guard let destination = Self.destination(for: text, searchEnabled: searchEnabled, searchEngine: searchEngine) else { return }
        load(destination)
    }

    private static func isRunnerAddress(_ text: String) -> Bool {
        text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            == runnerAddress
    }

    static func destination(for text: String, searchEnabled: Bool = true, searchEngine: SearchEngine = .duckDuckGo) -> URL? {
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "about"].contains(scheme) {
            return url
        }
        // Address-like (a dot, no spaces): try it as https.
        if !text.contains(" "), text.contains("."), let url = URL(string: "https://" + text), url.host != nil {
            return url
        }
        // With search off, no query ever leaves — coerce the text to an https address instead.
        guard searchEnabled else {
            let stripped = text.split(separator: " ").joined()
            return URL(string: "https://" + stripped)
        }
        // Otherwise a search on the chosen engine — user-typed, submit-only (no keystroke egress ever).
        return searchEngine.searchURL(for: text)
    }

    func load(_ url: URL) {
        isRunnerPresented = false
        loadError = nil
        webView.load(URLRequest(url: url))
    }

    func reloadOrStop() {
        guard !isRunnerPresented else { return }
        if isLoading {
            webView.stopLoading()
        } else if webView.url != nil {
            loadError = nil
            webView.reload()
        } else {
            commitURLBar()
        }
    }

    func retryAfterError() {
        let target = loadError?.failingURL ?? currentURL
        loadError = nil
        if let target { load(target) } else { webView.reload() }
    }

    func dismissRunner() {
        isRunnerPresented = false
        urlText = currentURL?.absoluteString ?? ""
    }

    func goBack() {
        if isRunnerPresented {
            dismissRunner()
        } else {
            webView.goBack()
        }
    }
    func goForward() { webView.goForward() }
    func focusURLBar() { urlBarFocusToken += 1 }

    func zoom(by factor: Double) {
        webView.pageZoom = min(max(webView.pageZoom * factor, 0.4), 3.0)
    }
    func resetZoom() { webView.pageZoom = 1.0 }

    // MARK: - Handoff to the engine

    /// Send one shelf candidate to the app: streams resolve to the quality picker, files download
    /// directly, `.page` runs the extractor with the browser's whole cookie jar.
    func download(_ item: SniffedItem) {
        guard let url = item.resolvedURL, !MediaSniffer.isNoise(item.url) else { return }
        let handoffKey = MediaSniffer.recordKey(item.url)
        guard handedOffKeys.insert(handoffKey).inserted else { return }
        let kind = item.type
        var filename = item.filename.flatMap(CapturedDownload.sanitizedFileName)
        // A sniffed stream's URL names its manifest ("master.m3u8"), not the video — hand the
        // engine the page title as the save-name stem; `addMedia` appends the container extension
        // once the plan is known.
        if kind == .stream, filename == nil, !media.pageTitle.isEmpty {
            filename = CapturedDownload.sanitizedFileName(media.pageTitle)
        }
        Task { [weak self] in
            guard let self else { return }
            let cookies = await BrowserStore.shared.cookieHeader(for: url)
            let jar = kind == .page ? await BrowserStore.shared.writeNetscapeJar() : nil
            let capture = CapturedDownload(
                url: url,
                extractFromPage: kind == .page ? true : nil,
                suggestedFileName: filename,
                referrer: referrerForHandoff,
                cookies: cookies,
                userAgent: userAgent,
                source: .builtInBrowser
            )
            sink?.browserCapture(capture, kind: kind, cookiesFile: jar)
        }
    }

    /// Extract this page's media via yt-dlp — the shelf's explicit action, available even when
    /// the sniffer saw nothing directly (MSE-only sites).
    func extractCurrentPage() {
        guard let url = currentURL else { return }
        download(SniffedItem(url: url.absoluteString, type: .page,
                             label: pageTitle.isEmpty ? url.absoluteString : pageTitle, extract: true))
    }

    /// A download the browser would have performed itself (attachment, unrenderable type,
    /// ⌥-click…) — cancelled in WebKit and handed to the engine with full page context.
    /// `kind` routes it (`.stream` sends a downloaded manifest through the quality picker).
    func takeOver(url: URL, suggestedFilename: String?, mimeType: String?, kind: SniffedItem.ItemType = .file) {
        guard !MediaSniffer.isNoise(url.absoluteString) else { return }
        let handoffKey = MediaSniffer.recordKey(url.absoluteString)
        guard handedOffKeys.insert(handoffKey).inserted else { return }
        let filename = CapturedDownload.sanitizedFileName(suggestedFilename)
        Task { [weak self] in
            guard let self else { return }
            let cookies = await BrowserStore.shared.cookieHeader(for: url)
            let capture = CapturedDownload(
                url: url,
                suggestedFileName: filename,
                referrer: referrerForHandoff,
                cookies: cookies,
                userAgent: userAgent,
                source: .builtInBrowser
            )
            sink?.browserCapture(capture, kind: kind, cookiesFile: nil)
        }
        // A popup whose very first act was downloading has no other content — close it.
        if openedByPage && !hasCommittedNavigation { shouldClose = true }
    }

    var referrerForHandoff: String? {
        if !media.pageURL.isEmpty { return media.pageURL }
        return currentURL?.absoluteString
    }

    // MARK: - Lifecycle

    func markCommitted(url: URL?) {
        hasCommittedNavigation = true
        favicon = nil
        media.reset(pageURL: url?.absoluteString ?? "")
        shelfItems = []
        handedOffKeys = []
    }

    func applySniff(_ envelope: SniffEnvelope) {
        media.apply(envelope)
        shelfItems = media.candidates
    }

    /// Turn ad/tracker blocking on or off for this web view: attach every compiled content-rule
    /// list (curated + downloaded) or detach them all. Synchronous and idempotent — the cached
    /// lists attach ahead of the window's first load, which starts in the same run-loop turn.
    /// Compiles finishing later bump `AppModel.browserContentRulesGeneration`, and the view calls
    /// this again — so a session converges on the right lists without racing any compile.
    func setAdBlock(_ enabled: Bool) {
        adBlockEnabled = enabled
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        guard enabled else { return }
        for list in BrowserStore.shared.activeRuleLists {
            controller.add(list)
        }
    }

    func captureUserAgentIfNeeded() {
        guard userAgent == nil else { return }
        webView.evaluateJavaScript("navigator.userAgent") { [weak self] result, _ in
            MainActor.assumeIsolated {
                if let agent = result as? String, !agent.isEmpty { self?.userAgent = agent }
            }
        }
    }

    /// Best-effort favicon for the current page. Fetched *inside* the page context (isolated world,
    /// but the page's cookies and origin) so it adds no new egress beyond the browsing the user is
    /// already doing, and returned as a base64 data URL. Cross-origin icons without CORS, SVG data,
    /// or a missing file simply leave it nil — the chrome falls back to a globe.
    func refreshFavicon() {
        webView.callAsyncJavaScript(Self.faviconScript, in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard case .success(let value) = result, let dataURL = value as? String,
                      let image = Self.decodeFaviconDataURL(dataURL) else { return }
                self?.favicon = image
            }
        }
    }

    private static let faviconScript = """
    const rels = ["link[rel~='icon']", "link[rel='shortcut icon']", "link[rel='apple-touch-icon']"];
    let href = null;
    for (const sel of rels) { const el = document.querySelector(sel); if (el && el.href) { href = el.href; break; } }
    if (!href) { href = location.origin + '/favicon.ico'; }
    try {
        const resp = await fetch(href, { cache: 'force-cache' });
        if (!resp.ok) { return null; }
        const blob = await resp.blob();
        if (!blob.size || blob.size > 524288) { return null; }
        return await new Promise((resolve) => {
            const reader = new FileReader();
            reader.onloadend = () => resolve(reader.result);
            reader.onerror = () => resolve(null);
            reader.readAsDataURL(blob);
        });
    } catch (e) { return null; }
    """

    private static func decodeFaviconDataURL(_ string: String) -> NSImage? {
        guard let marker = string.range(of: ";base64,") else { return nil }
        let base64 = String(string[marker.upperBound...])
        guard let data = Data(base64Encoded: base64), !data.isEmpty,
              let image = NSImage(data: data) else { return nil }
        return image
    }

    /// Whether the crash handler should quietly reload (first crash in a while) or show the error
    /// state (crash loop).
    func shouldAutoRecoverFromCrash() -> Bool {
        let now = Date()
        defer { lastCrashRecovery = now }
        if let last = lastCrashRecovery, now.timeIntervalSince(last) < 60 { return false }
        return true
    }

    func presentLoadError(_ message: String, failingURL: URL?, isOffline: Bool = false) {
        loadError = BrowserLoadError(message: message, failingURL: failingURL, isOffline: isOffline)
    }

    func clearLoadError() { loadError = nil }

    /// Resolve everything pending and detach from WebKit — called when the window goes away.
    /// (Un-called WebKit completion handlers are a hang/assert; never leave them dangling.)
    func teardown() {
        dialog?.cancel()
        dialog = nil
        authRequest?.cancel()
        authRequest = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.messageHandlerName, contentWorld: .page
        )
        observations = []
    }
}

/// Breaks the `WKUserContentController` → handler retain cycle (the controller retains its
/// message handlers strongly; the session must not be immortal).
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler & AnyObject)?

    init(_ target: any WKScriptMessageHandler & AnyObject) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
