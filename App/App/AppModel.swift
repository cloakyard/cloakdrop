import SwiftUI
import Observation
import UniformTypeIdentifiers
import DownloadModels
import DownloadEngine

/// An add that matched a download already in the catalog — by URL, by same-origin ETag, or by an
/// already-completed file of the same name and size — awaiting the user's "download again?" decision.
/// Held in a FIFO so several at once (e.g. a re-pasted batch) confirm one at a time.
struct DuplicateAdd: Identifiable, Equatable {
    let id = UUID()
    var request: DownloadRequest
    /// The existing download this add matched, and why.
    let match: DuplicateMatch

    var existingFileName: String { match.existing.fileName }
    var reason: DuplicateReason { match.reason }
    /// Whether the matched download has finished (so we can offer "Reveal in Finder").
    var existingIsOnDisk: Bool { match.existing.status == .completed }
}

/// The single source of UI truth. Owns the `DownloadManager`, mirrors its event stream into
/// observable state, and exposes intent-style actions the views call. `@MainActor` so all
/// SwiftUI-facing state is touched on the main actor; the engine does the concurrent work.
@MainActor
@Observable
final class AppModel {
    // Catalog state (status-level; mutated on discrete transitions).
    private(set) var downloads: [Download] = []
    // Fast-moving per-download metrics (mutated ~10×/sec, kept out of the array above).
    private(set) var progress: [UUID: DownloadProgress] = [:]
    private(set) var queues: [DownloadQueue] = []
    private(set) var settings: EngineSettings = .default
    /// User-defined routing rules, in evaluation order. Mirrored from the engine.
    private(set) var rules: [SmartRule] = []
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

    // View state.
    var selection: SidebarSelection? = .smart(.all)
    var selectedDownloadIDs: Set<UUID> = []
    var searchText: String = ""
    var sort: DownloadSort = .dateAdded
    var isAddSheetPresented = false
    var isBatchSheetPresented = false
    /// Which Settings tab is shown; a menu command can steer this (e.g. "About CloakDrop").
    var settingsSelection: SettingsTab = .general

    /// A URL to pre-fill the add sheet with (e.g. from a clipboard banner or drop).
    var pendingAddURL: String?
    /// A clipboard-detected link awaiting the user's "Add" / "Dismiss" decision.
    private(set) var detectedClipboardURL: URL?

    /// A resolved media stream awaiting the user's quality selection in the picker (see
    /// `AppModel+Media`). Settable within the module rather than `private(set)` so the media-intake
    /// extension can drive it.
    var pendingMediaSelection: MediaSelection?
    /// True while a manifest/page URL is being fetched and parsed, before a grab starts.
    var isResolvingMedia = false
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

    /// The bundled page extractor (yt-dlp), if present — resolves page URLs (YouTube & 1800+ sites)
    /// into real format tiers. `nil` in a checkout/build without the vendored binary.
    private(set) var mediaExtractor: (any MediaExtractor)?
    /// Whether the bundled extractor actually ran (its version probe succeeded in-sandbox at launch).
    private(set) var isPageExtractionAvailable = false

    /// Reopens/raises the main window (set where SwiftUI's `openWindow` is available). Browser
    /// media grabs call it so the quality picker — hosted by the main window — is actually visible
    /// even when that window was closed.
    @ObservationIgnored var raiseMainWindow: (() -> Void)?

    /// Adds that matched an existing download by URL, each awaiting a "download again?" decision.
    /// FIFO so several confirm one at a time; the alert binds to the head.
    private(set) var pendingDuplicateAdds: [DuplicateAdd] = []
    var currentDuplicateAdd: DuplicateAdd? { pendingDuplicateAdds.first }

    /// Whether the built-in browser's address bar treats non-URL text as a DuckDuckGo search (on)
    /// or always tries it as an `https://` address (off). Off means zero query egress from typing.
    /// Persisted in UserDefaults.
    var browserSearchEnabled: Bool {
        didSet { UserDefaults.standard.set(browserSearchEnabled, forKey: Self.browserSearchKey) }
    }
    static let browserSearchKey = "browserSearchEnabled"

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
    private(set) var launchAtLoginEnabled: Bool = false

    let manager: DownloadManager
    private let dock = DockProgressController()
    private let notifications = NotificationManager()
    /// Keychain-backed store for per-site HTTP/FTP credentials the user asks CloakDrop to remember.
    private let siteCredentialStore: any CredentialStoring = KeychainCredentialStore()
    /// Latch so the post-completion action fires once per "work → drained" cycle, not on every drain.
    private var postCompletionArmed = false
    private let clipboard = ClipboardMonitor()
    private let loginItem = LoginItemService()
    private let sleepPreventer = SleepPreventer()
    private var eventTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var didBootstrap = false

    init(manager: DownloadManager) {
        self.manager = manager
        self.clipboardMonitoringEnabled = UserDefaults.standard.bool(forKey: Self.clipboardKey)
        self.askQualityEnabled = UserDefaults.standard.bool(forKey: Self.askQualityKey)
        self.grabSubtitlesEnabled = UserDefaults.standard.bool(forKey: Self.grabSubtitlesKey)
        // Address-bar search defaults ON (absent key → true) for a browser that feels normal.
        self.browserSearchEnabled = UserDefaults.standard.object(forKey: Self.browserSearchKey) as? Bool ?? true
        self.launchAtLoginEnabled = loginItem.isEnabled
    }

    /// Build the live, production-backed app model.
    static func live() throws -> AppModel {
        AppModel(manager: try AppEnvironment.makeManager())
    }

    // MARK: Lifecycle

    func bootstrap() async {
        // SwiftUI's `.task` can fire more than once (the main window is reopened to surface a
        // capture), but the engine's event streams are single-consumer — re-subscribing strands the
        // UI (events land in the store but never reach a live consumer). Run the setup exactly once.
        guard !didBootstrap else { return }
        didBootstrap = true
        await notifications.requestAuthorization()
        notifications.onAction = { [weak self] action in
            Task { @MainActor in self?.handleNotificationAction(action) }
        }
        do {
            try await manager.start()
        } catch {
            // Persistence failed to open; surface nothing destructive — start empty.
        }
        let snapshot = await manager.snapshot()
        downloads = snapshot.downloads
        queues = snapshot.queues
        settings = snapshot.settings
        rules = snapshot.rules
        stats = snapshot.stats
        startObservingEvents()
        refreshAmbient()

        // Locate the bundled page extractor (yt-dlp) and confirm it actually runs inside our sandbox —
        // a launch-time smoke test of the bundled binary. `isPageExtractionAvailable` reflects the
        // probe; page grabs (YouTube etc.) route through it.
        let extractor = YtDlpExtractor.locate()
        mediaExtractor = extractor
        if let extractor {
            Task { [weak self] in
                let version = await extractor.version()
                self?.isPageExtractionAvailable = (version != nil)
                NSLog("[CloakDrop] page extractor (yt-dlp): %@", version ?? "unavailable")
            }
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
        drainCaptureInbox()
        CaptureInboxObserver.shared.start { [weak self] in self?.drainCaptureInbox() }

        // One-time tidy-up of the removed browser extensions' native-messaging manifests.
        LegacyExtensionCleanup.runIfNeeded()
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
            if download.status.isTerminal || download.status == .completed { progress[download.id] = nil }
            if download.status == .completed, download.isMedia { ensureThumbnail(for: download) }
        case .downloadRemoved(let id):
            downloads.removeAll { $0.id == id }
            progress[id] = nil
            selectedDownloadIDs.remove(id)
        case .progress(let p):
            progress[p.id] = p
        case .queuesChanged(let q):
            queues = q
        case .settingsChanged(let s):
            settings = s
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

    // MARK: Derived

    var effectiveSelection: SidebarSelection { selection ?? .smart(.all) }

    var filteredDownloads: [Download] {
        let active = effectiveSelection
        var result = downloads.filter { active.matches($0) }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            result = result.filter {
                $0.fileName.lowercased().contains(query) || $0.url.absoluteString.lowercased().contains(query)
            }
        }
        return result.sorted(by: sortComparator)
    }

    private func sortComparator(_ a: Download, _ b: Download) -> Bool {
        switch sort {
        case .dateAdded: return a.createdAt > b.createdAt
        case .name: return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
        case .size: return (a.totalBytes ?? 0) > (b.totalBytes ?? 0)
        case .status: return a.status.rawKind < b.status.rawKind
        }
    }

    var activeCount: Int {
        downloads.filter { $0.status == .downloading }.count
    }

    var aggregateSpeed: Double {
        progress.values.reduce(0) { $0 + $1.bytesPerSecond }
    }

    /// Overall progress across in-flight downloads, for the Dock badge. `nil` if nothing active.
    var aggregateFraction: Double? {
        let active = downloads.filter { $0.status == .downloading }
        guard !active.isEmpty else { return nil }
        var done: Int64 = 0
        var total: Int64 = 0
        for d in active {
            let current = progress[d.id]?.downloadedBytes ?? d.downloadedBytes
            done += current
            total += d.totalBytes ?? current
        }
        guard total > 0 else { return nil }
        return min(1, Double(done) / Double(total))
    }

    func liveDownloadedBytes(_ download: Download) -> Int64 {
        progress[download.id]?.downloadedBytes ?? download.downloadedBytes
    }

    /// The byte total to show — live from the engine when it has one (a media grab learns its total
    /// from the segments' response heads), else the persisted value (`nil` while a media grab's
    /// total is still unknown).
    func liveTotalBytes(_ download: Download) -> Int64? {
        progress[download.id]?.totalBytes ?? download.totalBytes
    }

    func liveSpeed(_ download: Download) -> Double {
        progress[download.id]?.bytesPerSecond ?? 0
    }

    /// Peak transfer rate to show in the summary — live while downloading, else the persisted value.
    func peakSpeed(_ download: Download) -> Double {
        progress[download.id]?.peakBytesPerSecond ?? download.peakBytesPerSecond ?? 0
    }

    /// Average transfer rate over active time — live while downloading, else the persisted value.
    func averageSpeed(_ download: Download) -> Double {
        progress[download.id]?.averageBytesPerSecond ?? download.averageBytesPerSecond ?? 0
    }

    func liveFraction(_ download: Download) -> Double? {
        progress[download.id]?.fractionCompleted ?? download.fractionCompleted
    }

    func eta(_ download: Download) -> TimeInterval? {
        progress[download.id]?.estimatedTimeRemaining
    }

    var selectedDownload: Download? {
        guard selectedDownloadIDs.count == 1, let id = selectedDownloadIDs.first else { return nil }
        return downloads.first { $0.id == id }
    }

    // MARK: Actions

    /// Enqueue an add — but if the catalog already holds this download (same URL, same-origin ETag,
    /// or an already-completed file of the same name and size), don't silently create a duplicate;
    /// surface a confirmation instead (the user can still choose to re-download via
    /// `confirmDuplicateAdd`). Every intake path funnels through here, so the guard applies uniformly.
    /// A `preview` from the add sheet's pre-flight sharpens detection with the resource's ETag/size.
    func add(_ request: DownloadRequest, preview: LinkPreview? = nil) {
        let fileName = request.suggestedFileName ?? FileNaming.fileName(url: request.url)
        let candidate = DuplicateCandidate(request: request.url, fileName: fileName, preview: preview)
        if let match = DuplicateDetector.findDuplicate(of: candidate, in: downloads) {
            pendingDuplicateAdds.append(DuplicateAdd(request: request, match: match))
        } else {
            commitAdd(request, preview: preview)
        }
    }

    private func commitAdd(_ request: DownloadRequest, preview: LinkPreview? = nil) {
        Task { await manager.add(request, preview: preview) }
    }

    // MARK: Link intelligence (pre-flight)

    /// Pre-flight a URL against the server — best-effort — so the add sheet can show what's actually
    /// there (final URL after redirects, size, type, resumability, connection estimate) before the
    /// user commits. Returns `nil` when the server can't be reached; the caller degrades gracefully.
    func preview(
        url: URL,
        referrer: String? = nil,
        cookies: String? = nil,
        username: String? = nil,
        password: String? = nil
    ) async -> LinkPreview? {
        await manager.preview(url: url, username: username, password: password, referrer: referrer, cookies: cookies)
    }

    /// User chose to re-download a duplicate: give it a unique file name so the new transfer doesn't
    /// overwrite the existing file (finalize replaces a same-named file), then enqueue it. Advances
    /// to the next pending duplicate, if any.
    func confirmDuplicateAdd() {
        guard var pending = pendingDuplicateAdds.first else { return }
        pendingDuplicateAdds.removeFirst()
        let base = pending.request.suggestedFileName ?? FileNaming.fileName(url: pending.request.url)
        pending.request.suggestedFileName = uniqueFileName(base: base, inDirectory: pending.request.destinationDirectoryPath)
        commitAdd(pending.request)
    }

    func cancelDuplicateAdd() {
        if !pendingDuplicateAdds.isEmpty { pendingDuplicateAdds.removeFirst() }
    }

    /// User chose to look at the file they already have instead of downloading it again: reveal the
    /// matched download in Finder and dismiss the prompt.
    func revealExistingDuplicate() {
        guard let pending = pendingDuplicateAdds.first else { return }
        pendingDuplicateAdds.removeFirst()
        revealInFinder(pending.match.existing)
    }

    /// A file name not already used (in the catalog or on disk) in `directory`, appending " (2)",
    /// " (3)", … before the extension until it's free — the browser-style de-collision.
    private func uniqueFileName(base: String, inDirectory directory: String) -> String {
        func taken(_ name: String) -> Bool {
            downloads.contains { $0.destinationDirectoryPath == directory && $0.fileName == name }
                || FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(name))
        }
        guard taken(base) else { return base }
        let ns = base as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        var counter = 2
        while counter < 10_000 {
            let candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            if !taken(candidate) { return candidate }
            counter += 1
        }
        return base
    }

    /// Build a request from a raw URL string and the default destination, then enqueue it.
    @discardableResult
    func quickAdd(urlString: String, into directory: URL = AppEnvironment.defaultDownloadsDirectory()) -> Bool {
        guard let url = Self.normalizedURL(urlString) else { return false }
        let request = DownloadRequest(url: url, destinationDirectoryPath: directory.path)
        add(request)
        return true
    }

    /// Fetch a single user-entered page and extract its downloadable links (the "grab everything on
    /// this page" flow). One user-initiated request to the page the user typed — never a crawler; it
    /// does not follow the links it finds. The body is size-capped so a pathological page can't blow up.
    func extractPageLinks(from pageURL: URL, extensions: Set<String> = []) async -> [URL] {
        var request = URLRequest(url: pageURL)
        request.timeoutInterval = 20
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return [] }
        let capped = data.prefix(10 * 1024 * 1024)
        let html = String(bytes: capped, encoding: .utf8) ?? String(bytes: capped, encoding: .isoLatin1) ?? ""
        return PageLinkExtractor.extract(html: html, baseURL: pageURL, extensions: extensions)
    }

    /// Enqueue a specific set of already-parsed URLs (the link-grabber's selected rows).
    func addURLs(_ urls: [URL], into directory: URL = AppEnvironment.defaultDownloadsDirectory(), bookmark: Data? = nil) {
        for url in urls {
            add(DownloadRequest(url: url, destinationDirectoryPath: directory.path, destinationBookmark: bookmark))
        }
    }

    /// Accept dropped web URLs or text links onto the window.
    @discardableResult
    func acceptDrop(urls: [URL], strings: [String]) -> Bool {
        var added = false
        for url in urls where url.scheme == "http" || url.scheme == "https" {
            add(DownloadRequest(url: url, destinationDirectoryPath: AppEnvironment.defaultDownloadsDirectory().path))
            added = true
        }
        for string in strings where URLBatch.normalized(string) != nil {
            _ = quickAdd(urlString: string)
            added = true
        }
        return added
    }

    /// User accepted a clipboard-detected link: open the add sheet pre-filled with it.
    func addDetectedClipboardURL() {
        guard let url = detectedClipboardURL else { return }
        pendingAddURL = url.absoluteString
        detectedClipboardURL = nil
        isAddSheetPresented = true
    }

    func dismissDetectedClipboardURL() {
        detectedClipboardURL = nil
    }

    // MARK: External capture (cloakdrop:// link, Safari/browser extension, share sheet)

    /// Handle an incoming deep link or opened file. A `cloakdrop://add?…` URL becomes a
    /// `CapturedDownload`; a `.metalink`/`.meta4` file becomes one or more multi-source downloads;
    /// anything else is ignored.
    func handleIncomingURL(_ url: URL) {
        if url.isFileURL {
            if Self.isMetalink(url) { openMetalink(url) }
            return
        }
        guard url.scheme?.lowercased() == "cloakdrop" else { return }
        guard let capture = try? CapturedDownload.parse(cloakdropURL: url) else { return }
        enqueueCapture(capture)
    }

    /// Pull every capture the Share extension / deep links dropped into the shared App Group inbox and start
    /// them. Called on the Darwin wake signal and once on launch (for anything that arrived while the
    /// app was closed).
    func drainCaptureInbox() {
        for capture in CaptureInbox.drain() { enqueueCapture(capture) }
    }

    /// Start a captured download immediately — no confirm step, since the user already chose to
    /// download it in the browser (the pill) or share sheet. A *page* capture goes to the extractor
    /// (auto-best tier, or the picker when "Ask me quality" is on); a video+audio pair is muxed;
    /// anything else takes the normal download path. Duplicate detection still guards a re-add.
    func enqueueCapture(_ capture: CapturedDownload) {
        let request = capture.toRequest(destinationDirectoryPath: AppEnvironment.defaultDownloadsDirectory().path)
        if capture.extractFromPage == true {
            grabFromPage(capture)
        } else if let audioURL = capture.audioURL {
            // A video URL paired with a separate audio URL (adaptive source with no manifest): grab
            // both and mux them so the download has sound.
            grabPairedMedia(request, audioURL: audioURL)
        } else {
            grab(request)
        }
    }

    /// Surface a transient, auto-dismissing media error (protected stream, sign-in wall, unavailable).
    func presentMediaError(_ message: String) {
        mediaExtractionError = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if self?.mediaExtractionError == message { self?.mediaExtractionError = nil }
        }
    }

    func pause(_ id: UUID) { Task { await manager.pause(id: id) } }
    func resume(_ id: UUID) { Task { await manager.resume(id: id) } }
    func cancel(_ id: UUID) { Task { await manager.cancel(id: id) } }
    func remove(_ id: UUID, deleteFile: Bool) { Task { await manager.remove(id: id, deleteFile: deleteFile) } }

    func removeSelected(deleteFile: Bool) { selectedDownloadIDs.forEach { remove($0, deleteFile: deleteFile) } }

    func pauseAll() { Task { await manager.pauseAll() } }
    func resumeAll() { Task { await manager.resumeAll() } }
    func clearCompleted() { Task { await manager.clearCompleted() } }

    /// Recompute lifetime stats (e.g. when the Stats tab appears, so "today" is fresh after midnight).
    func refreshStats() { Task { await manager.reloadStats() } }
    /// Clear every recorded download total (Settings ▸ Stats ▸ Reset).
    func resetStats() { Task { await manager.resetStats() } }

    /// Whether any completed download is present (drives the "Clear Completed" command).
    var hasCompleted: Bool { downloads.contains { $0.status == .completed } }

    func updateSettings(_ newSettings: EngineSettings) {
        settings = newSettings
        Task { await manager.updateSettings(newSettings) }
        // Keep the built-in browser on the same route as the engine.
        BrowserStore.shared.applyProxy(newSettings.resolvedProxy)
    }

    // MARK: Smart rules

    /// The next `order` value for a newly-created rule (appends to the end of the priority list).
    var nextRuleOrder: Int { (rules.map(\.order).max() ?? -1) + 1 }

    func saveRule(_ rule: SmartRule) { Task { await manager.saveRule(rule) } }
    func deleteRule(_ id: UUID) { Task { await manager.deleteRule(id: id) } }

    /// Reorder rules from a SwiftUI `.onMove` (source offsets → destination), then persist the new
    /// priority order.
    func moveRules(fromOffsets source: IndexSet, toOffset destination: Int) {
        var reordered = rules
        reordered.move(fromOffsets: source, toOffset: destination)
        rules = reordered   // optimistic local update so the list doesn't jump before the event
        Task { await manager.reorderRules(reordered.map(\.id)) }
    }

    /// Turn "open at login" on or off. Reflects the actual resulting OS state afterward (so a failed
    /// or approval-gated change never leaves the switch lying), and nudges the user to System
    /// Settings when re-enabling needs their approval.
    func setLaunchAtLogin(_ enabled: Bool) {
        try? loginItem.setEnabled(enabled)
        if enabled, loginItem.needsApproval { loginItem.openSystemSettings() }
        launchAtLoginEnabled = loginItem.isEnabled
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
