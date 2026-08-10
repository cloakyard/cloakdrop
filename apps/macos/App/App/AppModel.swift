import AppKit
import Observation
import UniformTypeIdentifiers
import DownloadModels
import DownloadEngine

/// The single source of UI truth. Owns the `DownloadManager`, mirrors its event stream into
/// observable state, and exposes intent-style actions the views call. `@MainActor` so all
/// SwiftUI-facing state is touched on the main actor; the engine does the concurrent work.
@MainActor
@Observable
final class AppModel {
    // Catalog state (status-level; mutated on discrete transitions).
    private(set) var downloads: [Download] = []
    // Fast-moving per-download metrics (mutated ~10×/sec, kept out of the array above — and boxed,
    // so a tick touches one box, not this dictionary; the dictionary itself changes only when a
    // transfer starts or ends).
    private(set) var progress: [UUID: ProgressBox] = [:]
    private(set) var queues: [DownloadQueue] = []
    var settings: EngineSettings = .default
    /// User-defined routing rules, in evaluation order. Mirrored from the engine.
    var rules: [SmartRule] = []
    /// Lifetime download totals (today / this month / all-time), shown in Settings ▸ Stats.
    private(set) var stats: DownloadStats = .empty
    /// The single owner of speed-test runs (Settings ▸ Speed Test, menu bar). One runner on
    /// the app model — not per-view — so concurrent surfaces can't start duelling tests.
    let speedTest = SpeedTestRunner()

    /// Poster-frame thumbnails for completed video grabs, keyed by download id (see
    /// `AppModel+Thumbnails`). Settable within the module so that extension can populate it.
    var mediaThumbnails: [UUID: URL] = [:]
    /// Downloads whose thumbnail is currently being generated, so overlapping triggers don't duplicate.
    var thumbnailsInFlight: Set<UUID> = []
    /// Downloads whose thumbnail generation already failed this session (audio-only, unreadable) —
    /// consulted so every row appearance doesn't retry a doomed render.
    var thumbnailsUnavailable: Set<UUID> = []

    // View state.
    var selection: SidebarSelection? = .smart(.all)
    var selectedDownloadIDs: Set<UUID> = []
    var searchText: String = ""
    var sort: DownloadSort = .dateAdded
    var isAddSheetPresented = false
    var isBatchSheetPresented = false
    /// Which Settings tab is shown; a menu command can steer this (e.g. "About CloakDrop").
    var settingsSelection: SettingsTab = .general
    /// Becomes true only after persisted settings have configured both engine and browser routing.
    /// Network-capable UI stays disabled until then, so a restored manual proxy cannot be bypassed
    /// during the brief async launch window.
    private(set) var isNetworkReady = false
    private(set) var startupError: String?

    /// A URL to pre-fill the add sheet with (e.g. from a clipboard banner or drop).
    var pendingAddURL: String?
    /// A clipboard-detected link awaiting the user's "Add" / "Dismiss" decision.
    var detectedClipboardURL: URL?

    /// A resolved media stream awaiting the user's quality selection in the picker (see
    /// `AppModel+Media`). Settable within the module rather than `private(set)` so the media-intake
    /// extension can drive it.
    var pendingMediaSelection: MediaSelection?
    /// True while a manifest/page URL is being fetched and parsed, before a grab starts. Counted,
    /// not a flag: overlapping resolutions each hold a unit, so the first to finish can't clear
    /// the shared spinner while another is still in flight.
    var isResolvingMedia: Bool { mediaResolveWork > 0 }
    private var mediaResolveWork = 0
    func beginMediaResolve() { mediaResolveWork += 1 }
    func endMediaResolve() { mediaResolveWork = max(0, mediaResolveWork - 1) }
    /// A transient, human-readable reason a media grab couldn't be prepared (protected stream, sign-in
    /// wall, unavailable video) — surfaced as an auto-dismissing toast. Set via `presentMediaError`.
    var mediaExtractionError: String?

    /// Whether to show the quality picker for a multi-tier grab. Off (default) grabs the best tier
    /// immediately — one click, no dialog; on offers every resolution. Persisted in UserDefaults.
    var askQualityEnabled: Bool {
        didSet { UserDefaults.standard.set(askQualityEnabled, forKey: Self.askQualityKey) }
    }
    private static let askQualityKey = "askQualityEnabled"

    /// Whether to fetch a subtitle sidecar (`.srt`) when a grabbed video offers one. Off (default)
    /// grabs no subtitles on the one-click path; the quality picker always offers per-language choice
    /// regardless. Persisted in UserDefaults.
    var grabSubtitlesEnabled: Bool {
        didSet { UserDefaults.standard.set(grabSubtitlesEnabled, forKey: Self.grabSubtitlesKey) }
    }
    private static let grabSubtitlesKey = "grabSubtitlesEnabled"

    /// The bundled page extractor (yt-dlp), if present — resolves supported page URLs
    /// into real format tiers. `nil` when the helper is absent or cannot launch in the sandbox.
    private(set) var mediaExtractor: (any MediaExtractor)?

    /// Reopens/raises the main window (set where SwiftUI's `openWindow` is available). Browser
    /// media grabs call it so the quality picker — hosted by the main window — is actually visible
    /// even when that window was closed.
    @ObservationIgnored var raiseMainWindow: (() -> Void)?

    /// Adds that matched an existing download by URL, each awaiting a "download again?" decision.
    /// FIFO so several confirm one at a time; the alert binds to the head.
    var pendingDuplicateAdds: [DuplicateAdd] = []
    var currentDuplicateAdd: DuplicateAdd? { pendingDuplicateAdds.first }

    /// Whether the built-in browser's address bar treats non-URL text as a search (on) or always
    /// tries it as an `https://` address (off). Off means zero query egress from typing.
    /// Persisted in UserDefaults.
    var browserSearchEnabled: Bool {
        didSet { UserDefaults.standard.set(browserSearchEnabled, forKey: Self.browserSearchKey) }
    }
    static let browserSearchKey = "browserSearchEnabled"

    /// Which search engine the address bar uses for a typed query. Persisted in UserDefaults.
    var browserSearchEngine: SearchEngine {
        didSet { UserDefaults.standard.set(browserSearchEngine.rawValue, forKey: Self.browserSearchEngineKey) }
    }
    static let browserSearchEngineKey = "browserSearchEngine"

    /// Whether the built-in browser blocks ads, trackers, and ad popups (a compiled WebKit content
    /// rule list + ad-host popup rejection). **Off by default** — the user opts in from Settings ▸
    /// Browser. Persisted in UserDefaults.
    var browserAdBlockEnabled: Bool {
        didSet {
            UserDefaults.standard.set(browserAdBlockEnabled, forKey: Self.browserAdBlockKey)
            if browserAdBlockEnabled { prepareContentBlocking() }
        }
    }
    static let browserAdBlockKey = "browserAdBlockEnabled"

    /// Which blocklist the ad blocker uses: the built-in curated ruleset, or a downloadable
    /// open-source domain list layered on top of it. Persisted in UserDefaults. Choosing a
    /// downloadable list that has never been fetched triggers its first download — that pick (like
    /// the Update button) is the user action the privacy contract requires; nothing fetches on a
    /// timer or at launch.
    var browserBlocklistSource: BlocklistSource {
        didSet {
            UserDefaults.standard.set(browserBlocklistSource.rawValue, forKey: Self.browserBlocklistSourceKey)
            if oldValue != browserBlocklistSource { blocklistSourceChanged() }
        }
    }
    static let browserBlocklistSourceKey = "browserBlocklistSource"

    /// Metadata of the active downloaded blocklist (count + freshness), `nil` for built-in/none.
    var blocklistInfo: BlocklistInfo?
    /// Whether a blocklist download is in flight (drives the Update button's spinner).
    var isUpdatingBlocklist = false
    /// The last update failure, user-presentable; cleared by the next attempt or source switch.
    var blocklistUpdateError: String?
    /// The one selected-source activation/update pipeline. Replacing it cancels every stage of the
    /// previous source's work; the generation keeps same-source replacements from clearing newer UI.
    @ObservationIgnored var blocklistTask: Task<Void, Never>?
    @ObservationIgnored var blocklistTaskGeneration = 0
    /// Bumped whenever the set of compiled content-rule lists changes — open browser windows
    /// observe it and re-apply their lists. Blocklist intents live in `AppModel+Browser.swift`.
    var browserContentRulesGeneration = 0

    /// Whether clipboard monitoring is on. Persisted in UserDefaults.
    var clipboardMonitoringEnabled: Bool {
        didSet {
            UserDefaults.standard.set(clipboardMonitoringEnabled, forKey: Self.clipboardKey)
            if clipboardMonitoringEnabled {
                clipboard.start()
            } else {
                clipboard.stop()
                detectedClipboardURL = nil
            }
        }
    }
    private static let clipboardKey = "clipboardMonitoringEnabled"

    /// Whether CloakDrop opens at login — and so, after a reboot, comes back and resumes any
    /// downloads that were in flight. Backed by `SMAppService` (the OS is the source of truth); this
    /// mirrors it so the Settings toggle reflects the real state.
    var launchAtLoginEnabled: Bool = false

    let manager: DownloadManager
    private let dock = DockProgressController()
    private let notifications = NotificationManager()
    /// Keychain-backed store for per-site HTTP/FTP credentials the user asks CloakDrop to remember.
    private let siteCredentialStore: any CredentialStoring = KeychainCredentialStore()
    /// Latch so the post-completion action fires once per "work → drained" cycle, not on every drain.
    private var postCompletionArmed = false
    private let clipboard = ClipboardMonitor()
    let loginItem = LoginItemService()
    private let sleepPreventer = SleepPreventer()
    private var eventTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var notificationAuthorizationTask: Task<Void, Never>?
    private var didBootstrap = false
    static let pendingIntakeLimit = 128
    @ObservationIgnored var pendingIncomingURLs: [URL] = []
    @ObservationIgnored var pendingCaptures: [CapturedDownload] = []

    init(manager: DownloadManager) {
        self.manager = manager
        self.clipboardMonitoringEnabled = UserDefaults.standard.bool(forKey: Self.clipboardKey)
        self.askQualityEnabled = UserDefaults.standard.bool(forKey: Self.askQualityKey)
        self.grabSubtitlesEnabled = UserDefaults.standard.bool(forKey: Self.grabSubtitlesKey)
        // Address-bar search defaults ON (absent key → true) for a browser that feels normal.
        self.browserSearchEnabled = UserDefaults.standard.object(forKey: Self.browserSearchKey) as? Bool ?? true
        // Default to DuckDuckGo (the most private of the offered engines).
        self.browserSearchEngine = UserDefaults.standard.string(forKey: Self.browserSearchEngineKey)
            .flatMap(SearchEngine.init(rawValue:)) ?? .duckDuckGo
        // Ad/tracker blocking defaults OFF (absent key → false) — opt-in.
        self.browserAdBlockEnabled = UserDefaults.standard.bool(forKey: Self.browserAdBlockKey)
        self.browserBlocklistSource = UserDefaults.standard.string(forKey: Self.browserBlocklistSourceKey)
            .flatMap(BlocklistSource.init(rawValue:)) ?? .builtIn
        self.launchAtLoginEnabled = loginItem.isEnabled
        if browserAdBlockEnabled { prepareContentBlocking() }
    }

    /// Build the live, production-backed app model.
    static func live() throws -> AppModel {
        AppModel(manager: try AppEnvironment.makeManager())
    }

    #if DEBUG
    /// Build the deterministic catalog used by `--hero-fixture`. Keeping this behind DEBUG makes
    /// the capture repeatable without shipping sample data or ever opening the user's database.
    static func heroFixture() throws -> AppModel {
        let model = AppModel(manager: try AppEnvironment.makeHeroFixtureManager())
        let fixture = HeroFixtureState.make()
        model.downloads = fixture.downloads
        model.queues = [.makeDefault]
        model.progress = [fixture.activeDownloadID: ProgressBox(fixture.progress)]
        model.selectedDownloadIDs = [fixture.activeDownloadID]
        // The fixture is already a complete UI snapshot. Skip the live manager bootstrap, which
        // would replace it with an empty in-memory catalog and start ambient services.
        model.didBootstrap = true
        model.isNetworkReady = true
        return model
    }
    #endif

    // MARK: Lifecycle

    func bootstrap() async {
        // SwiftUI's `.task` can fire more than once (the main window is reopened to surface a
        // capture), but the engine's event streams are single-consumer — re-subscribing strands the
        // UI (events land in the store but never reach a live consumer). Run the setup exactly once.
        guard !didBootstrap else { return }
        didBootstrap = true
        startupError = nil
        notifications.onAction = { [weak self] action in self?.handleNotificationAction(action) }
        do {
            try await manager.start()
        } catch {
            startupError = error.localizedDescription
            didBootstrap = false
            return
        }
        let snapshot = await manager.snapshot()
        downloads = snapshot.downloads
        queues = snapshot.queues
        settings = snapshot.settings
        BrowserStore.shared.applyProxy(settings.resolvedProxy)
        rules = snapshot.rules
        stats = snapshot.stats
        startObservingEvents()
        refreshAmbient()
        isNetworkReady = true

        // Offer page extraction only after the bundled helper has actually run in the sandbox.
        // Locating an executable is not enough: an invalid signature or damaged runtime can still
        // make launch fail, and the UI must not advertise a feature that cannot work.
        if let extractor = YtDlpExtractor.locate() {
            let version = await extractor.version()
            if version != nil { mediaExtractor = extractor }
            NSLog("[CloakDrop] page extractor (yt-dlp): %@", version ?? "unavailable")
        }

        clipboard.onURLDetected = { [weak self] url in
            guard let self else { return }
            // Ignore links we already have, and don't nag about the same one twice.
            guard !self.downloads.contains(where: { $0.url == url }), self.detectedClipboardURL != url else { return }
            self.detectedClipboardURL = url
        }
        if clipboardMonitoringEnabled { clipboard.start() }

        // Drain any captures the share extension / deep links dropped while we were launching, then
        // watch for new ones arriving via the Darwin wake signal.
        let incomingURLs = pendingIncomingURLs
        pendingIncomingURLs.removeAll()
        for url in incomingURLs { handleIncomingURL(url) }
        let captures = pendingCaptures
        pendingCaptures.removeAll()
        for capture in captures { enqueueCapture(capture) }
        drainCaptureInbox()
        CaptureInboxObserver.shared.start { [weak self] in self?.drainCaptureInbox() }
        notificationAuthorizationTask = Task { [notifications] in
            await notifications.requestAuthorization()
        }
    }

    func retryBootstrap() {
        Task { await bootstrap() }
    }

    private func startObservingEvents() {
        // Two streams: reliable status events, and a separate lossy progress stream. Both feed
        // `apply` on the main actor, so status updates are never starved by a progress flood.
        eventTask?.cancel()
        eventTask = Task { [weak self, manager] in
            for await event in manager.events {
                self?.apply(event)
            }
        }
        progressTask?.cancel()
        progressTask = Task { [weak self, manager] in
            for await event in manager.progressEvents {
                self?.apply(event)
            }
        }
    }

    private func apply(_ event: EngineEvent) {
        switch event {
        case .downloadAdded(let download):
            upsert(download)
            postCompletionArmed = true   // new work means the next drain should fire the action again
        case .downloadUpdated(let download):
            let previous = downloads.first { $0.id == download.id }?.status
            upsert(download)
            if download.status != previous { announce(transition: download, from: previous) }
            if download.status == .downloading { postCompletionArmed = true }
            if download.status.isTerminal { progress[download.id] = nil }
            if download.status == .completed, download.isMedia { ensureThumbnail(for: download) }
        case .downloadRemoved(let id):
            downloads.removeAll { $0.id == id }
            progress[id] = nil
            selectedDownloadIDs.remove(id)
        case .progress(let p):
            applyProgress(p)
        case .queuesChanged(let q):
            queues = q
        case .settingsChanged(let s):
            settings = s
            BrowserStore.shared.applyProxy(s.resolvedProxy)
        case .rulesChanged(let r):
            rules = r
        case .statsChanged(let s):
            stats = s
        case .allDownloadsCompleted:
            // Fire once per drain: the engine signals this on every completion that leaves the queue
            // empty, so without a latch, finishing a later one-off download would re-run the user's
            // Shortcut / re-notify. Re-armed when new/active work appears (above).
            if postCompletionArmed {
                postCompletionArmed = false
                applyPostCompletionAction()
            }
        }
        // Ambient surfaces (the Dock progress ring/badge) are derived from full O(n) scans of
        // `downloads`. Status events are infrequent, so refresh right away; the ~10/sec-per-download
        // progress firehose is coalesced so a large catalog isn't rescanned on every tick.
        if case .progress = event {
            refreshAmbientThrottled()
        } else {
            refreshAmbient()
        }
    }

    /// Route a tick into its download's box — or drop it when the download is gone or finished
    /// (a tick still buffered after the terminal event would resurrect a ghost entry, permanently
    /// inflating the menu bar's aggregate speed).
    private func applyProgress(_ p: DownloadProgress) {
        if let box = progress[p.id] {
            box.value = p
        } else if downloads.contains(where: { $0.id == p.id && !$0.status.isTerminal }) {
            progress[p.id] = ProgressBox(p)
        }
    }

    /// The user's "when everything finishes" preference. Every branch is sandbox-safe — the most
    /// powerful, `runShortcut`, delegates to the user's own Shortcut via a URL open, so CloakDrop
    /// itself never needs a sleep/shutdown/Apple-Events entitlement.
    private func applyPostCompletionAction() {
        switch settings.resolvedPostAction {
        case .none:
            break
        case .notify:
            notifications.notifyAllCompleted()
        case .quit:
            NSApplication.shared.terminate(nil)
        case .runShortcut:
            runPostCompletionShortcut()
        }
    }

    /// Launch the user's chosen Shortcut via `shortcuts://run-shortcut?name=…`. Opening a URL is
    /// fully sandbox-legal, and Shortcuts is where the user composes whatever they actually want to
    /// happen (sleep the Mac, empty a folder, ping a webhook) — so this one hook covers them all.
    private func runPostCompletionShortcut() {
        guard let name = settings.postCompletionShortcutName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return }
        // `URLQueryItem`/`urlQueryAllowed` does NOT escape `&`, `=`, or `+`, so a Shortcut named
        // "Backup & Sync" would parse as name="Backup " plus a junk param and run the wrong (or no)
        // shortcut. Percent-encode against alphanumerics so every reserved character is escaped.
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func upsert(_ download: Download) {
        if let index = downloads.firstIndex(where: { $0.id == download.id }) {
            downloads[index] = download
        } else {
            downloads.append(download)
        }
    }

    // MARK: Ambient surfaces

    @ObservationIgnored private var lastAmbientRefresh: ContinuousClock.Instant?
    @ObservationIgnored private let ambientClock = ContinuousClock()

    /// Coalesce progress-driven ambient refreshes to ~3/sec so the Dock update (and the two full
    /// `downloads` scans behind it) doesn't run on every progress tick of every active download.
    private func refreshAmbientThrottled() {
        let now = ambientClock.now
        if let last = lastAmbientRefresh, last.duration(to: now) < .milliseconds(333) { return }
        refreshAmbient()
    }

    private func refreshAmbient() {
        lastAmbientRefresh = ambientClock.now
        let active = activeCount
        dock.update(fraction: aggregateFraction, activeCount: active)
        sleepPreventer.update(active: active > 0)
    }

    private func announce(transition download: Download, from previous: DownloadStatus?) {
        switch download.status {
        case .completed:
            notifications.notifyCompleted(download)
        case .failed(let reason):
            notifications.notifyFailed(download, reason: reason)
        default:
            break
        }
    }

    private func handleNotificationAction(_ action: NotificationManager.Action) {
        guard let download = downloads.first(where: { $0.id == action.downloadID }) else { return }
        switch action.kind {
        case .open: open(download)
        case .reveal: revealInFinder(download)
        case .retry: resume(download.id)
        }
    }

    /// Store a site's HTTP/FTP credentials in the Keychain so the user needn't retype them next time.
    func rememberSiteCredentials(host: String, username: String, password: String) {
        guard !host.isEmpty, !(username.isEmpty && password.isEmpty) else { return }
        siteCredentialStore.setCredential(StoredCredential(username: username, password: password),
                                          forKey: KeychainCredentialStore.siteKey(host: host))
    }

    /// Recall a site's saved credentials, if any (for the add sheet's auto-fill).
    func siteCredentials(forHost host: String) -> (username: String, password: String)? {
        guard !host.isEmpty,
              let credential = siteCredentialStore.credential(forKey: KeychainCredentialStore.siteKey(host: host))
        else { return nil }
        return (credential.username, credential.password)
    }

    /// Write a download's provenance receipt to a user-chosen file (Save panel). The receipt is a
    /// plain-text record; nothing leaves the Mac unless the user picks a destination here.
    func saveProvenanceReceipt(_ receipt: ProvenanceReceipt) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(receipt.fileName) — receipt.txt"
        panel.allowedContentTypes = [.plainText]
        panel.message = String(localized: "Save the verified-download receipt.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? receipt.exportText().data(using: .utf8)?.write(to: url)
    }

    // MARK: Helpers

    /// Accepts bare hosts and adds https:// when no scheme is present.
    static func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https", "ftp", "ftps"].contains(scheme) {
            return url
        }
        // Accept a bare host only if it actually looks like one (a dotted name/IP or localhost) — the
        // same guard URLBatch.normalized applies — so a stray word like "notes" doesn't become a
        // guaranteed-to-fail https://notes download.
        if let url = URL(string: "https://\(trimmed)"), let host = url.host(),
           host == "localhost" || host.contains(".") {
            return url
        }
        return nil
    }
}
