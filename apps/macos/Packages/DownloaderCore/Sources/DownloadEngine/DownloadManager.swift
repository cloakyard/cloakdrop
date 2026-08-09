import Foundation
import DownloadModels
import DownloadPersistence

/// Initial state handed to the UI on launch.
public struct EngineSnapshot: Sendable {
    public let downloads: [Download]
    public let queues: [DownloadQueue]
    public let settings: EngineSettings
    public let rules: [SmartRule]
    public let stats: DownloadStats
}

/// The engine's coordinator: the single entry point the app talks to.
///
/// Owns the catalog of downloads and queues, enforces per-queue concurrency, persists all
/// state, and drives one `DownloadTask` per active transfer. Emits an `AsyncStream` of
/// `EngineEvent`s the view model renders. Auto-resumes interrupted downloads when network
/// connectivity returns. Being an actor, all of this mutable coordination state is race-free.
public actor DownloadManager {
    let store: any DownloadStore
    let httpClient: any HTTPClient
    let networkMonitor: any NetworkPathMonitoring
    let globalLimiter: BandwidthLimiter
    let remuxer: any Remuxer
    let signatureInspector: any CodeSignatureInspecting
    /// Where the manual-proxy password lives — the Keychain in production — so it never touches the
    /// settings JSON on disk.
    private let credentialStore: any CredentialStoring

    var settings: EngineSettings = .default
    var downloads: [UUID: Download] = [:]
    var queues: [UUID: DownloadQueue] = [:]
    /// Cached lifetime download totals, loaded at `start()` and refreshed on each completion, so
    /// `snapshot()` can stay synchronous. The store holds the durable per-day buckets.
    var currentStats: DownloadStats = .empty
    /// User-defined routing rules, kept sorted by `order` (evaluation priority).
    private var rules: [SmartRule] = []
    var tasks: [UUID: DownloadTask] = [:]
    var handles: [UUID: Task<Void, Never>] = [:]
    var autoPaused: Set<UUID> = []
    var networkReachable = true
    /// In-order persistence chains, one per download: each save runs after the previous one for the
    /// same id, so two rapid status flips can never reach the store out of order (a stale `.queued`
    /// landing after `.paused` would restart a paused download on relaunch).
    var pendingSaves: [UUID: Task<Void, Never>] = [:]

    let eventContinuation: AsyncStream<EngineEvent>.Continuation
    /// Status-level engine events (add/update/remove/queues/settings/completion). Unbounded so a
    /// burst of high-frequency progress can never evict a status event. One consumer.
    public nonisolated let events: AsyncStream<EngineEvent>

    let progressContinuation: AsyncStream<EngineEvent>.Continuation
    /// High-frequency `.progress` events on their own bounded, lossy stream (latest wins), kept
    /// separate so shedding excess under load never drops a status event. One consumer.
    public nonisolated let progressEvents: AsyncStream<EngineEvent>

    var monitorTask: Task<Void, Never>?
    var schedulerTask: Task<Void, Never>?
    var bandwidthTask: Task<Void, Never>?

    deinit {
        // These timers loop for the manager's lifetime; nothing else cancels them, so without this a
        // discarded manager (notably every test's) leaks three tasks that keep firing for the process's
        // life. `[weak self]` lets the manager deallocate, but the loops never stop on their own.
        monitorTask?.cancel()
        schedulerTask?.cancel()
        bandwidthTask?.cancel()
    }

    public init(
        store: any DownloadStore,
        httpClient: any HTTPClient = SchemeRoutingHTTPClient(),
        networkMonitor: any NetworkPathMonitoring = NetworkMonitor(),
        remuxer: any Remuxer = AVFoundationRemuxer(),
        signatureInspector: any CodeSignatureInspecting = SecCodeSignatureInspector(),
        credentialStore: any CredentialStoring = KeychainCredentialStore()
    ) {
        self.store = store
        self.httpClient = httpClient
        self.networkMonitor = networkMonitor
        self.remuxer = remuxer
        self.signatureInspector = signatureInspector
        self.credentialStore = credentialStore
        self.globalLimiter = BandwidthLimiter(bytesPerSecond: nil)
        // Status events must not be dropped (a lost `.downloadAdded` strands a row in limbo), so
        // they get an unbounded stream. Progress events are lossy-tolerant and ride a separate
        // bounded stream that sheds the excess instead of evicting status events.
        let (statusStream, statusContinuation) = AsyncStream<EngineEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = statusStream
        self.eventContinuation = statusContinuation
        let (progressStream, progressCont) = AsyncStream<EngineEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.progressEvents = progressStream
        self.progressContinuation = progressCont
    }

    /// Load persisted state, re-queue anything that was mid-flight, and begin monitoring the
    /// network. Call once at launch.
    public func start() async throws {
        try await store.bootstrap()
        settings = try await store.loadSettings()
        // The persisted proxy password is always blank (it lives in the Keychain); restore it into the
        // in-memory settings so the connection can authenticate and the UI can show it this session.
        hydrateProxyPassword()
        await globalLimiter.setRate(bytesPerSecond: effectiveGlobalLimit())
        await httpClient.configure(proxy: settings.resolvedProxy)

        for queue in try await store.allQueues() { queues[queue.id] = queue }
        if queues[DownloadQueue.defaultQueueID] == nil {
            let def = DownloadQueue.makeDefault
            queues[def.id] = def
        }

        rules = (try await store.allRules()).sorted { $0.order < $1.order }

        for var download in try await store.allDownloads() {
            if settings.resumeDownloadsOnLaunch {
                // Auto-resume: anything mid-transfer when we quit becomes queued to restart.
                if download.status == .downloading { download.status = .queued }
            } else if download.status == .downloading || download.status == .queued {
                // The user chose to keep interrupted downloads paused until they start them.
                download.status = .paused
            }
            downloads[download.id] = download
        }
        currentStats = (try? await store.loadStats(asOf: Date())) ?? .empty

        startNetworkMonitoring()
        startScheduler()
        startBandwidthScheduler()
        promoteScheduled(asOf: Date())
        scheduleAllQueues()
    }

    /// Snapshot for initial UI population.
    public func snapshot() -> EngineSnapshot {
        EngineSnapshot(
            downloads: Array(downloads.values).sorted { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) },
            queues: Array(queues.values).sorted { $0.order < $1.order },
            settings: settings,
            rules: rules,
            stats: currentStats
        )
    }

    public func currentSettings() -> EngineSettings { settings }

    /// Recompute lifetime totals from the store (e.g. when the Stats tab opens, or after midnight has
    /// rolled the "today" bucket) and publish the result.
    public func reloadStats() async {
        currentStats = (try? await store.loadStats(asOf: Date())) ?? currentStats
        eventContinuation.yield(.statsChanged(currentStats))
    }

    /// Clear every recorded download total (Settings ▸ Stats ▸ Reset).
    public func resetStats() async {
        try? await store.resetStats()
        // Reload rather than assume empty: if a download completed during the reset, its bytes are
        // already back in the store — publish the store's truth so the two can't disagree.
        currentStats = (try? await store.loadStats(asOf: Date())) ?? .empty
        eventContinuation.yield(.statsChanged(currentStats))
    }
    public func currentRules() -> [SmartRule] { rules }

    // MARK: - Link intelligence (pre-flight)

    /// Pre-flight a URL against the server *without* committing a download: resolve redirects and
    /// read size, range-support, file name, and type, then compute how many connections the engine
    /// would open. Referrer/cookies are folded into headers exactly as `add` does, so the preview
    /// reflects the request the download would actually make.
    ///
    /// Best-effort: returns `nil` when the server can't be reached or refuses the probe — a preview
    /// is a convenience, never a precondition for adding.
    public func preview(
        url: URL,
        headers: [String: String] = [:],
        username: String? = nil,
        password: String? = nil,
        referrer: String? = nil,
        cookies: String? = nil
    ) async -> LinkPreview? {
        var merged = headers
        if let referrer, !referrer.isEmpty { merged["Referer"] = referrer }
        if let cookies, !cookies.isEmpty { merged["Cookie"] = cookies }
        return try? await LinkInspector(httpClient: httpClient).inspect(
            url: url,
            headers: merged,
            username: username,
            password: password,
            settings: settings
        )
    }

    // MARK: - Adding downloads

    @discardableResult
    public func add(_ request: DownloadRequest, preview: LinkPreview? = nil) async -> Download {
        // Suggested names cross several engine entry points (manual adds, browser capture, Metalink),
        // so enforce the single-component invariant here rather than trusting every caller to sanitize.
        let proposedFileName = FileNaming.fileName(suggested: request.suggestedFileName, url: request.url)

        // Apply the first matching smart rule (routing to a folder/queue, a speed cap, auto-start).
        // The pre-flight preview, when present, contributes MIME/size so those conditions can fire —
        // all evaluated on-device, no extra network call.
        let ruleInput = RuleInput(
            url: request.url,
            fileName: proposedFileName,
            category: FileCategory.classify(fileName: proposedFileName),
            mimeType: preview?.mimeType,
            sizeBytes: preview?.totalBytes
        )
        let effectiveRequest = SmartRuleEngine.resolve(request, input: ruleInput, rules: rules).request

        let fileName = reserveUniqueFileName(
            proposedFileName, inDirectory: effectiveRequest.destinationDirectoryPath
        )

        let order = (downloads.values.map(\.order).max() ?? -1) + 1

        // Fold the convenience capture fields into standard request headers.
        var headers = effectiveRequest.requestHeaders
        if let referrer = effectiveRequest.referrer, !referrer.isEmpty { headers["Referer"] = referrer }
        if let cookies = effectiveRequest.cookies, !cookies.isEmpty { headers["Cookie"] = cookies }

        var download = Download(
            url: effectiveRequest.url,
            mirrors: effectiveRequest.mirrors.isEmpty ? nil : effectiveRequest.mirrors,
            fileName: fileName,
            destinationDirectoryPath: effectiveRequest.destinationDirectoryPath,
            destinationBookmark: effectiveRequest.destinationBookmark,
            requestedSegmentCount: effectiveRequest.segmentCount.map {
                min(settings.maxSegmentCount, max(1, $0))
            },
            queueID: queues[effectiveRequest.queueID] != nil ? effectiveRequest.queueID : DownloadQueue.defaultQueueID,
            requestHeaders: headers,
            speedLimitBytesPerSecond: effectiveRequest.speedLimitBytesPerSecond,
            username: effectiveRequest.username,
            password: effectiveRequest.password,
            checksum: effectiveRequest.checksum,
            scheduledStart: effectiveRequest.scheduledStart,
            recurrence: effectiveRequest.recurrence,
            order: order
        )

        if let scheduled = effectiveRequest.scheduledStart, scheduled > Date() {
            download.status = .scheduled
        } else {
            download.status = effectiveRequest.startImmediately ? .queued : .paused
        }

        downloads[download.id] = download
        await persistOrderedAndWait(download)
        eventContinuation.yield(.downloadAdded(download))

        if download.status == .queued {
            scheduleQueue(download.queueID)
        }
        return download
    }

    /// Add a media (HLS/DASH) grab: a resolved `MediaPlan` becomes a `Download` on the media
    /// transfer path. Otherwise identical to `add` — same queue, persistence, and scheduling.
    @discardableResult
    public func addMedia(_ request: DownloadRequest, plan: MediaPlan) async -> Download {
        let fileName = reserveMediaFileName(for: request, plan: plan)
        let order = (downloads.values.map(\.order).max() ?? -1) + 1

        var headers = request.requestHeaders
        if let referrer = request.referrer, !referrer.isEmpty { headers["Referer"] = referrer }
        // A flattened Cookie header no longer carries domain/path scope. Never forward page cookies
        // to a different media host (for example youtube.com → googlevideo.com): apart from leaking
        // unrelated session data, some signed CDNs reject an otherwise valid URL with HTTP 403.
        // Exact-host media keeps the cookie for authenticated same-origin manifests.
        let mediaURLs = plan.segments.map(\.url)
            + (plan.audioSegments ?? []).map(\.url)
            + [plan.initSegment?.url, plan.audioInitSegment?.url].compactMap { $0 }
            + (plan.subtitles ?? []).flatMap { $0.segments.map(\.url) }
            + Array(plan.keyURLs)
        let sourceHost = request.url.host?.lowercased()
        let crossesHost = mediaURLs.contains { $0.host?.lowercased() != sourceHost }
        if crossesHost {
            for key in headers.keys where key.caseInsensitiveCompare("Cookie") == .orderedSame {
                headers.removeValue(forKey: key)
            }
        } else if let cookies = request.cookies, !cookies.isEmpty {
            headers["Cookie"] = cookies
        }

        var download = Download(
            url: request.url,
            fileName: fileName,
            destinationDirectoryPath: request.destinationDirectoryPath,
            destinationBookmark: request.destinationBookmark,
            queueID: queues[request.queueID] != nil ? request.queueID : DownloadQueue.defaultQueueID,
            requestHeaders: headers,
            speedLimitBytesPerSecond: request.speedLimitBytesPerSecond,
            username: request.username,
            password: request.password,
            order: order,
            mediaPlan: plan
        )
        download.status = request.startImmediately ? .queued : .paused

        downloads[download.id] = download
        await persistOrderedAndWait(download)
        eventContinuation.yield(.downloadAdded(download))

        if download.status == .queued { scheduleQueue(download.queueID) }
        return download
    }

    // MARK: - Lifecycle controls

    public func pause(id: UUID) async {
        guard let download = downloads[id] else { return }
        if let task = tasks[id] {
            let handle = handles[id]
            await task.requestStop(.pause)
            handle?.cancel()
            // Wait for the task to fully unwind (its terminal ".paused" persist runs here) before
            // returning. Otherwise a resume() issued in the gap sets .queued, then the task's late
            // taskFinished() clobbers it back to .paused and the download is stuck. Mirrors cancel().
            await handle?.value
        } else if download.status.isActive || download.status == .scheduled {
            update(id: id) { $0.status = .paused }
        }
    }

    public func resume(id: UUID) async {
        guard let download = downloads[id], !download.status.isTerminal else { return }
        autoPaused.remove(id)
        update(id: id) { $0.status = .queued }
        scheduleQueue(download.queueID)
    }

    public func cancel(id: UUID) async {
        guard let download = downloads[id] else { return }
        if let task = tasks[id] {
            let handle = handles[id]
            await task.requestStop(.cancel)
            handle?.cancel()
            // Wait for the task to fully unwind (its terminal persist runs here) so a later
            // remove() can't race with a resurrecting save.
            await handle?.value
        } else {
            SegmentedFileWriter.discardPartData(for: download)
            update(id: id) { $0.status = .canceled }
        }
    }

    public func remove(id: UUID, deleteFile: Bool) async {
        guard let download = downloads[id] else { return }
        // Stop any running transfer and wait for it to fully unwind (its terminal save runs
        // here) so it can't re-create the row after we delete it.
        if let task = tasks[id] {
            let handle = handles[id]
            await task.requestStop(.cancel)
            handle?.cancel()
            await handle?.value
        }
        // Drop from memory, then discard files and delete from the store. We deliberately do
        // NOT route through cancel()/update(): marking a terminal download ".canceled" and
        // persisting it via a detached task would race with the delete below.
        downloads[id] = nil
        tasks[id] = nil
        handles[id] = nil
        SegmentedFileWriter.discardPartData(for: download)
        if deleteFile {
            try? FileManager.default.removeItem(atPath: download.destinationFilePath)
        }
        // Drain any save still queued for this id so a straggler can't re-create the row after
        // the delete.
        await pendingSaves[id]?.value
        pendingSaves[id] = nil
        try? await store.delete(id: id)
        eventContinuation.yield(.downloadRemoved(id))
    }

    public func pauseAll() async {
        for id in downloads.keys where downloads[id]?.status.isActive == true {
            await pause(id: id)
        }
    }

    public func resumeAll() async {
        for download in downloads.values where download.status.isResumable {
            await resume(id: download.id)
        }
    }

    /// Drop every completed download from the catalog and the store. The finished files on
    /// disk are left untouched — this only clears them from the list.
    public func clearCompleted() async {
        let ids = downloads.values.filter { $0.status == .completed }.map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids {
            downloads[id] = nil
            eventContinuation.yield(.downloadRemoved(id))
        }
        try? await store.deleteCompleted()
    }

    // MARK: - Settings & queues

    public func updateSettings(_ newSettings: EngineSettings) async {
        // Keep the real proxy password in memory (to authenticate and to show in the UI this session),
        // but move it to the Keychain and persist a blanked copy so plaintext never reaches the DB.
        persistProxyPassword(from: newSettings)
        settings = newSettings
        await globalLimiter.setRate(bytesPerSecond: effectiveGlobalLimit())
        await httpClient.configure(proxy: newSettings.resolvedProxy)
        try? await store.save(settings: settingsForPersistence(newSettings))
        eventContinuation.yield(.settingsChanged(newSettings))
    }

    // MARK: Proxy credential ↔ Keychain

    /// Fill `settings.proxy.password` from the Keychain when the persisted copy is blank (the normal
    /// case) so the in-memory proxy can authenticate.
    private func hydrateProxyPassword() {
        guard var proxy = settings.proxy, proxy.mode == .manual, proxy.password.isEmpty else { return }
        let key = KeychainCredentialStore.proxyKey(host: proxy.host, port: proxy.port)
        guard let credential = credentialStore.credential(forKey: key) else { return }
        proxy.password = credential.password
        settings.proxy = proxy
    }

    /// Store the manual-proxy password in the Keychain (or remove it when cleared).
    private func persistProxyPassword(from newSettings: EngineSettings) {
        guard let proxy = newSettings.proxy, proxy.mode == .manual else { return }
        let key = KeychainCredentialStore.proxyKey(host: proxy.host, port: proxy.port)
        if proxy.password.isEmpty {
            credentialStore.setCredential(nil, forKey: key)
        } else {
            credentialStore.setCredential(StoredCredential(username: proxy.username, password: proxy.password), forKey: key)
        }
    }

    /// A copy of the settings safe to write to disk: the proxy password is blanked (it's in the
    /// Keychain). Blanked **unconditionally** — a stale plaintext password can linger in the field after
    /// the user switches the proxy mode away from `.manual`, and it must never reach the settings JSON.
    private func settingsForPersistence(_ source: EngineSettings) -> EngineSettings {
        var copy = source
        if copy.proxy != nil {
            copy.proxy?.password = ""
        }
        return copy
    }

    public func createQueue(_ queue: DownloadQueue) async {
        queues[queue.id] = queue
        try? await store.save(queue)
        eventContinuation.yield(.queuesChanged(Array(queues.values).sorted { $0.order < $1.order }))
    }

    // MARK: - Smart rules

    /// Insert or update a rule, then persist and publish the new rule list.
    public func saveRule(_ rule: SmartRule) async {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        rules.sort { $0.order < $1.order }
        try? await store.save(rule)
        eventContinuation.yield(.rulesChanged(rules))
    }

    public func deleteRule(id: UUID) async {
        rules.removeAll { $0.id == id }
        try? await store.deleteRule(id: id)
        eventContinuation.yield(.rulesChanged(rules))
    }

    /// Persist a full reordering (drag-to-reorder in the UI): renumber `order` to the given sequence
    /// of rule IDs and save each. Rules not named are left as-is.
    public func reorderRules(_ orderedIDs: [UUID]) async {
        for (index, id) in orderedIDs.enumerated() {
            guard let ruleIndex = rules.firstIndex(where: { $0.id == id }) else { continue }
            rules[ruleIndex].order = index
        }
        rules.sort { $0.order < $1.order }
        for rule in rules { try? await store.save(rule) }
        eventContinuation.yield(.rulesChanged(rules))
    }

}

private func < (lhs: (Int, Date), rhs: (Int, Date)) -> Bool {
    if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
    return lhs.1 < rhs.1
}
