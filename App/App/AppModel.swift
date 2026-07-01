import SwiftUI
import Observation
import DownloadModels
import DownloadEngine

/// An add that matched an existing download by URL, awaiting the user's "download again?"
/// decision. Held in a FIFO so several at once (e.g. a re-pasted batch) confirm one at a time.
struct DuplicateAdd: Identifiable, Equatable {
    let id = UUID()
    var request: DownloadRequest
    let existingFileName: String
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

    /// A download captured from a `cloakdrop://` link (and, later, a browser/share extension),
    /// held for a confirm-before-adding decision so nothing is ever queued silently.
    private(set) var pendingCapture: CapturedDownload?

    /// A resolved media stream awaiting the user's quality selection in the picker (see
    /// `AppModel+Media`). Settable within the module rather than `private(set)` so the media-intake
    /// extension can drive it.
    var pendingMediaSelection: MediaSelection?
    /// True while a manifest URL is being fetched and parsed, before the picker appears.
    var isResolvingMedia = false

    /// Adds that matched an existing download by URL, each awaiting a "download again?" decision.
    /// FIFO so several confirm one at a time; the alert binds to the head.
    private(set) var pendingDuplicateAdds: [DuplicateAdd] = []
    var currentDuplicateAdd: DuplicateAdd? { pendingDuplicateAdds.first }

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
    private let clipboard = ClipboardMonitor()
    private let loginItem = LoginItemService()
    private var eventTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var didBootstrap = false

    init(manager: DownloadManager) {
        self.manager = manager
        self.clipboardMonitoringEnabled = UserDefaults.standard.bool(forKey: Self.clipboardKey)
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
        startObservingEvents()
        refreshAmbient()

        clipboard.onURLDetected = { [weak self] url in
            guard let self else { return }
            // Ignore links we already have, and don't nag about the same one twice.
            guard !self.downloads.contains(where: { $0.url == url }), self.detectedClipboardURL != url else { return }
            self.detectedClipboardURL = url
        }
        if clipboardMonitoringEnabled { clipboard.start() }

        // Drain any captures the bundled extensions dropped while we were launching, then watch for
        // new ones arriving via the Darwin wake signal.
        drainCaptureInbox()
        CaptureInboxObserver.shared.start { [weak self] in self?.drainCaptureInbox() }
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
        case .downloadUpdated(let download):
            let previous = downloads.first { $0.id == download.id }?.status
            upsert(download)
            if download.status != previous { announce(transition: download, from: previous) }
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
        case .allDownloadsCompleted:
            applyPostCompletionAction()
        }
        refreshAmbient()
    }

    /// The user's "when everything finishes" preference. Sandbox-safe: only a clean quit.
    private func applyPostCompletionAction() {
        guard settings.resolvedPostAction == .quit else { return }
        NSApplication.shared.terminate(nil)
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

    func liveSpeed(_ download: Download) -> Double {
        progress[download.id]?.bytesPerSecond ?? 0
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

    /// Enqueue an add — but if a download for this exact URL already exists, don't silently create a
    /// duplicate; surface a confirmation instead (the user can still choose to re-download via
    /// `confirmDuplicateAdd`). Every intake path funnels through here, so the guard applies uniformly.
    func add(_ request: DownloadRequest) {
        if let existing = downloads.first(where: { $0.url == request.url }) {
            pendingDuplicateAdds.append(DuplicateAdd(request: request, existingFileName: existing.fileName))
        } else {
            commitAdd(request)
        }
    }

    private func commitAdd(_ request: DownloadRequest) {
        Task { await manager.add(request) }
    }

    /// User chose to re-download a duplicate: give it a unique file name so the new transfer doesn't
    /// overwrite the existing file (finalize replaces a same-named file), then enqueue it. Advances
    /// to the next pending duplicate, if any.
    func confirmDuplicateAdd() {
        guard var pending = pendingDuplicateAdds.first else { return }
        pendingDuplicateAdds.removeFirst()
        let base = pending.request.suggestedFileName ?? Self.fileName(fromURL: pending.request.url)
        pending.request.suggestedFileName = uniqueFileName(base: base, inDirectory: pending.request.destinationDirectoryPath)
        commitAdd(pending.request)
    }

    func cancelDuplicateAdd() {
        if !pendingDuplicateAdds.isEmpty { pendingDuplicateAdds.removeFirst() }
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

    /// The file name the engine would derive from a bare URL — the base for de-collision.
    static func fileName(fromURL url: URL) -> String {
        let last = url.lastPathComponent
        return (last.isEmpty || last == "/") ? "download" : last
    }

    /// Build a request from a raw URL string and the default destination, then enqueue it.
    @discardableResult
    func quickAdd(urlString: String, into directory: URL = AppEnvironment.defaultDownloadsDirectory()) -> Bool {
        guard let url = Self.normalizedURL(urlString) else { return false }
        let request = DownloadRequest(url: url, destinationDirectoryPath: directory.path)
        add(request)
        return true
    }

    /// Add every URL parsed (and pattern-expanded) from free-form text. Returns the count added.
    /// `bookmark` is the destination's security-scoped bookmark so batch downloads to a
    /// user-chosen folder keep working across relaunches under the sandbox.
    @discardableResult
    func batchAdd(
        text: String,
        into directory: URL = AppEnvironment.defaultDownloadsDirectory(),
        bookmark: Data? = nil
    ) -> Int {
        let urls = URLBatch.parse(text)
        for url in urls {
            add(DownloadRequest(url: url, destinationDirectoryPath: directory.path, destinationBookmark: bookmark))
        }
        return urls.count
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

    /// Captures waiting behind `pendingCapture` when several land at once — e.g. a burst from the
    /// browser extension, or an inbox drained on launch. The banner confirms one at a time.
    private var captureQueue: [CapturedDownload] = []

    /// Handle an incoming deep link. Parses a `cloakdrop://add?…` URL into a validated
    /// `CapturedDownload` and surfaces it for confirmation; non-cloakdrop or malformed links are
    /// ignored (nothing is queued without the user's explicit "Add").
    func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "cloakdrop" else { return }
        guard let capture = try? CapturedDownload.parse(cloakdropURL: url) else { return }
        enqueueCapture(capture)
    }

    /// Pull every capture the bundled extensions dropped into the shared App Group inbox and queue
    /// them for confirmation. Called on the Darwin wake signal and once on launch (for anything
    /// that arrived while the app was closed).
    func drainCaptureInbox() {
        for capture in CaptureInbox.drain() { enqueueCapture(capture) }
    }

    /// User accepted the captured download: enqueue it into the default downloads folder,
    /// carrying its referrer/cookies/user-agent, then advance to the next pending capture.
    func confirmPendingCapture() {
        guard let capture = pendingCapture else { return }
        grab(capture.toRequest(destinationDirectoryPath: AppEnvironment.defaultDownloadsDirectory().path))
        advancePendingCapture()
    }

    func dismissPendingCapture() {
        advancePendingCapture()
    }

    /// Surface a capture for confirmation, or hold it behind the one showing (reused by system capture).
    func enqueueCapture(_ capture: CapturedDownload) {
        if pendingCapture == nil {
            pendingCapture = capture
        } else {
            captureQueue.append(capture)
        }
    }

    private func advancePendingCapture() {
        pendingCapture = captureQueue.isEmpty ? nil : captureQueue.removeFirst()
    }

    func pause(_ id: UUID) { Task { await manager.pause(id: id) } }
    func resume(_ id: UUID) { Task { await manager.resume(id: id) } }
    func cancel(_ id: UUID) { Task { await manager.cancel(id: id) } }
    func remove(_ id: UUID, deleteFile: Bool) { Task { await manager.remove(id: id, deleteFile: deleteFile) } }

    func pauseSelected() { selectedDownloadIDs.forEach(pause) }
    func resumeSelected() { selectedDownloadIDs.forEach(resume) }
    func removeSelected(deleteFile: Bool) { selectedDownloadIDs.forEach { remove($0, deleteFile: deleteFile) } }

    func pauseAll() { Task { await manager.pauseAll() } }
    func resumeAll() { Task { await manager.resumeAll() } }
    func clearCompleted() { Task { await manager.clearCompleted() } }

    /// Whether any completed download is present (drives the "Clear Completed" command).
    var hasCompleted: Bool { downloads.contains { $0.status == .completed } }

    func updateSettings(_ newSettings: EngineSettings) {
        settings = newSettings
        Task { await manager.updateSettings(newSettings) }
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

    private func refreshAmbient() {
        dock.update(fraction: aggregateFraction, activeCount: activeCount)
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

    // MARK: Helpers

    /// Accepts bare hosts and adds https:// when no scheme is present.
    static func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme, scheme == "http" || scheme == "https" {
            return url
        }
        if let url = URL(string: "https://\(trimmed)"), url.host() != nil {
            return url
        }
        return nil
    }
}
