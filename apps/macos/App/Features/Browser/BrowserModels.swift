import Foundation
import DownloadModels

/// The search engine the address bar uses for a typed query. The query is only ever sent on Return
/// (submit-only) — there is no as-you-type suggestion traffic to any of these providers.
enum SearchEngine: String, CaseIterable, Identifiable, Sendable {
    case duckDuckGo
    case google
    case bing

    var id: String { rawValue }

    /// Brand name — a proper noun, shown verbatim in every locale.
    var displayName: String {
        switch self {
        case .duckDuckGo: "DuckDuckGo"
        case .google: "Google"
        case .bing: "Bing"
        }
    }

    /// The results URL for a user-typed query.
    func searchURL(for query: String) -> URL? {
        var components: URLComponents?
        switch self {
        case .duckDuckGo: components = URLComponents(string: "https://duckduckgo.com/")
        case .google: components = URLComponents(string: "https://www.google.com/search")
        case .bing: components = URLComponents(string: "https://www.bing.com/search")
        }
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

/// What the browser hands to the app — implemented by `AppModel`. A protocol seam (not AppModel
/// directly) so the browser feature stays testable in isolation.
@MainActor
protocol BrowserCaptureSink: AnyObject {
    /// A capture from the in-app browser: a sniffed candidate, a page extraction, or a download
    /// takeover. `kind` tells the router how to grab it; `cookiesFile` (Netscape jar, temp file,
    /// consumed and deleted by the sink) rides along for page extraction.
    func browserCapture(_ capture: CapturedDownload, kind: SniffedItem.ItemType, cookiesFile: URL?)
    /// Whether a page extractor is bundled and runnable — gates the shelf's extraction offer.
    var canExtractFromPages: Bool { get }
    func rememberSiteCredentials(host: String, username: String, password: String)
    func siteCredentials(forHost host: String) -> (username: String, password: String)?
}

/// A JavaScript dialog (`alert`/`confirm`/`prompt`) awaiting the user. WebKit hands us a
/// completion that MUST be called exactly once — the single-fire guard lives here so window
/// teardown and the button handler can both safely resolve.
@MainActor
final class BrowserDialog: Identifiable {
    enum Kind {
        case alert(() -> Void)
        case confirm((Bool) -> Void)
        case prompt(defaultText: String, (String?) -> Void)
    }

    let id = UUID()
    let message: String
    let host: String
    let kind: Kind
    private var finished = false

    init(message: String, host: String, kind: Kind) {
        self.message = message
        self.host = host
        self.kind = kind
    }

    var promptDefault: String {
        if case .prompt(let defaultText, _) = kind { return defaultText }
        return ""
    }

    func finish(confirmed: Bool = true, text: String? = nil) {
        guard !finished else { return }
        finished = true
        switch kind {
        case .alert(let done): done()
        case .confirm(let done): done(confirmed)
        case .prompt(_, let done): done(confirmed ? (text ?? "") : nil)
        }
    }

    /// The dismissive resolution — Escape, or the window going away mid-dialog.
    func cancel() { finish(confirmed: false, text: nil) }
}

/// An HTTP/proxy authentication challenge awaiting credentials.
@MainActor
final class BrowserAuthRequest: Identifiable {
    let id = UUID()
    let host: String
    let realm: String?
    let isProxy: Bool
    private let completion: (URLCredential?) -> Void
    private var finished = false

    init(host: String, realm: String?, isProxy: Bool, completion: @escaping (URLCredential?) -> Void) {
        self.host = host
        self.realm = realm
        self.isProxy = isProxy
        self.completion = completion
    }

    func finish(username: String, password: String) {
        guard !finished else { return }
        finished = true
        completion(URLCredential(user: username, password: password, persistence: .forSession))
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        completion(nil)
    }
}

/// A failed page load, rendered as the error overlay.
struct BrowserLoadError {
    var message: String
    var failingURL: URL?
    var isOffline = false
}
