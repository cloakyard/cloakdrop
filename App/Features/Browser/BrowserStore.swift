import WebKit
import Network
import DownloadModels

/// Process-wide browsing environment shared by every browser window: one persistent, identified
/// `WKWebsiteDataStore` (cookies/logins survive relaunch and are wiped by "Clear Browsing Data"),
/// the engine-proxy mirror, and the cookie exports the download handoff needs. No browsing
/// *history* exists anywhere — only site data.
@MainActor
final class BrowserStore {
    static let shared = BrowserStore()

    /// Fixed identifier so the same store is reopened every launch. Changing this orphans (not
    /// deletes) the previous store — never change it.
    private static let storeID = UUID(uuidString: "C10A0D09-51F3-4B8E-9E1C-2A47D2A6B001")!

    let dataStore: WKWebsiteDataStore

    /// The compiled ad/tracker content-rule list, cached after the first compile so opening more
    /// browser windows (or toggling the setting) is instant. `nil` until prepared or if compilation
    /// fails — in which case browsing simply proceeds unblocked (fail-open).
    private(set) var adBlockRuleList: WKContentRuleList?
    private var adBlockCompileTask: Task<WKContentRuleList?, Never>?

    private init() {
        dataStore = WKWebsiteDataStore(forIdentifier: Self.storeID)
    }

    /// A fresh configuration per web view (each needs its own user-content controller so message
    /// handlers don't collide), all sharing the one data store.
    func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        // Complete the UA to Safari's own ("… Version/26.0 Safari/605.1.15") — sites sniff for it
        // and serve their standard players/streams; a bare WebKit UA gets fallback experiences.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // The sniffing collector: page world (it must wrap the page's own fetch/XHR/MSE), every
        // frame (embedded players live in iframes), document start (hooks before page scripts run).
        configuration.userContentController.addUserScript(WKUserScript(
            source: MediaSniffer.collectorScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        ))
        return configuration
    }

    // MARK: - Ad / tracker blocking

    /// Compile (or reuse) the ad/tracker content-rule list. WebKit caches the compiled bytecode on
    /// disk keyed by identifier, so this is a fast lookup after the first launch; concurrent callers
    /// share one in-flight compile. Returns `nil` on failure so browsing degrades to unblocked
    /// rather than broken.
    func adBlockRuleList() async -> WKContentRuleList? {
        if let ready = adBlockRuleList { return ready }
        if let inFlight = adBlockCompileTask { return await inFlight.value }

        let task = Task<WKContentRuleList?, Never> {
            guard let store = WKContentRuleListStore.default() else { return nil }
            let identifier = AdBlockList.identifier
            // Reuse the already-compiled list when present; otherwise compile the JSON once.
            var list = await Self.lookUp(identifier, in: store)
            if list == nil {
                list = await Self.compile(identifier, json: AdBlockList.json, in: store)
            }
            await Self.evictStaleLists(keeping: identifier, in: store)
            return list
        }
        adBlockCompileTask = task
        let result = await task.value
        adBlockRuleList = result
        adBlockCompileTask = nil
        return result
    }

    /// Warm the compile in the background so the list is ready before a browser window opens.
    func prepareAdBlock() {
        Task { _ = await adBlockRuleList() }
    }

    private static func lookUp(_ identifier: String, in store: WKContentRuleListStore) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    private static func compile(_ identifier: String, json: String, in store: WKContentRuleListStore) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    /// Remove previously-compiled rule lists from older ruleset versions (their identifiers share our
    /// prefix but differ by content hash), so the on-disk store doesn't accumulate stale bytecode.
    private static func evictStaleLists(keeping current: String, in store: WKContentRuleListStore) async {
        let identifiers: [String] = await withCheckedContinuation { continuation in
            store.getAvailableContentRuleListIdentifiers { continuation.resume(returning: $0 ?? []) }
        }
        for identifier in identifiers where identifier != current && identifier.hasPrefix(AdBlockList.identifierPrefix) {
            await withCheckedContinuation { continuation in
                store.removeContentRuleList(forIdentifier: identifier) { _ in continuation.resume() }
            }
        }
    }

    // MARK: - Proxy mirror

    /// Mirror the engine's proxy into browsing. A manual proxy routes page traffic through the
    /// same host the downloads use; otherwise the browser follows the system configuration
    /// (WebKit's default when no explicit proxies are set).
    func applyProxy(_ proxy: DownloadModels.ProxyConfiguration) {
        guard proxy.mode == .manual, !proxy.host.isEmpty, let port = NWEndpoint.Port(rawValue: UInt16(clamping: proxy.port)) else {
            dataStore.proxyConfigurations = []
            return
        }
        let endpoint = NWEndpoint.hostPort(host: .init(proxy.host), port: port)
        var configuration: Network.ProxyConfiguration
        switch proxy.type {
        case .http, .https:
            configuration = Network.ProxyConfiguration(httpCONNECTProxy: endpoint)
        case .socks5:
            configuration = Network.ProxyConfiguration(socksv5Proxy: endpoint)
        }
        if !proxy.username.isEmpty {
            configuration.applyCredential(username: proxy.username, password: proxy.password)
        }
        dataStore.proxyConfigurations = [configuration]
    }

    // MARK: - Cookie exports

    /// The `Cookie:` header a request to `url` should carry, from the browser's jar — attached to
    /// engine downloads so they fetch exactly as the page would.
    func cookieHeader(for url: URL) async -> String? {
        BrowserCookies.cookieHeader(for: url, from: await dataStore.httpCookieStore.allCookies())
    }

    /// The whole jar as a Netscape `cookies.txt` in a private temp file (0600) for the yt-dlp
    /// resolver — multi-domain logins need their scoping intact. Callers delete it after use.
    func writeNetscapeJar() async -> URL? {
        let cookies = await dataStore.httpCookieStore.allCookies()
        guard !cookies.isEmpty else { return nil }
        let text = BrowserCookies.netscapeFile(cookies)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("browser-cookies", isDirectory: true)
        let file = directory.appendingPathComponent(UUID().uuidString + ".txt")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try text.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
    }

    /// Wipe every kind of site data (cookies, caches, local/session storage, IndexedDB, …) —
    /// the "Clear Browsing Data" action.
    func clearBrowsingData() async {
        await dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
    }
}
