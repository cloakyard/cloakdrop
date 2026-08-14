import SwiftUI
import DownloadModels
import DownloadEngine

extension AppModel {
    // MARK: Derived download state

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

    private func sortComparator(_ lhs: Download, _ rhs: Download) -> Bool {
        switch sort {
        case .dateAdded: return lhs.createdAt > rhs.createdAt
        case .name: return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
        case .size: return (lhs.totalBytes ?? 0) > (rhs.totalBytes ?? 0)
        case .status: return lhs.status.rawKind < rhs.status.rawKind
        }
    }

    var activeCount: Int { downloads.filter { $0.status == .downloading }.count }
    var aggregateSpeed: Double { progress.values.reduce(0) { $0 + $1.value.bytesPerSecond } }

    var aggregateFraction: Double? {
        let active = downloads.filter { $0.status == .downloading }
        guard !active.isEmpty else { return nil }
        var downloadedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        for download in active {
            let current = progress[download.id]?.value.downloadedBytes ?? download.downloadedBytes
            downloadedBytes += current
            totalBytes += download.totalBytes ?? current
        }
        guard totalBytes > 0 else { return nil }
        return min(1, Double(downloadedBytes) / Double(totalBytes))
    }

    func liveDownloadedBytes(_ download: Download) -> Int64 {
        progress[download.id]?.value.downloadedBytes ?? download.downloadedBytes
    }

    func liveTotalBytes(_ download: Download) -> Int64? {
        progress[download.id]?.value.totalBytes ?? download.totalBytes
    }

    func liveSpeed(_ download: Download) -> Double {
        progress[download.id]?.value.bytesPerSecond ?? 0
    }

    func peakSpeed(_ download: Download) -> Double {
        progress[download.id]?.value.peakBytesPerSecond ?? download.peakBytesPerSecond ?? 0
    }

    func averageSpeed(_ download: Download) -> Double {
        progress[download.id]?.value.averageBytesPerSecond ?? download.averageBytesPerSecond ?? 0
    }

    func liveFraction(_ download: Download) -> Double? {
        progress[download.id]?.value.fractionCompleted ?? download.fractionCompleted
    }

    func eta(_ download: Download) -> TimeInterval? {
        progress[download.id]?.value.estimatedTimeRemaining
    }

    var selectedDownload: Download? {
        guard selectedDownloadIDs.count == 1, let id = selectedDownloadIDs.first else { return nil }
        return downloads.first { $0.id == id }
    }

    // MARK: Download intake

    func add(_ request: DownloadRequest, preview: LinkPreview? = nil) {
        if let match = duplicateMatch(for: request, preview: preview) {
            pendingDuplicateAdds.append(DuplicateAdd(request: request, match: match))
        } else {
            commitAdd(request, preview: preview)
        }
    }

    private func duplicateMatch(for request: DownloadRequest, preview: LinkPreview? = nil) -> DuplicateMatch? {
        let fileName = request.suggestedFileName ?? FileNaming.fileName(url: request.url)
        return DuplicateDetector.findDuplicate(
            of: DuplicateCandidate(request: request.url, fileName: fileName, preview: preview),
            in: downloads
        )
    }

    private func commitAdd(_ request: DownloadRequest, preview: LinkPreview? = nil) {
        Task { await manager.add(request, preview: preview) }
    }

    func preview(
        url: URL,
        referrer: String? = nil,
        cookies: String? = nil,
        username: String? = nil,
        password: String? = nil
    ) async -> LinkPreview? {
        await manager.preview(url: url, username: username, password: password, referrer: referrer, cookies: cookies)
    }

    func confirmDuplicateAdd() {
        guard var pending = pendingDuplicateAdds.first else { return }
        pendingDuplicateAdds.removeFirst()
        let base = pending.request.suggestedFileName ?? FileNaming.fileName(url: pending.request.url)
        pending.request.suggestedFileName = uniqueFileName(
            base: base,
            inDirectory: pending.request.destinationDirectoryPath
        )
        commitAdd(pending.request)
    }

    func cancelDuplicateAdd() {
        if !pendingDuplicateAdds.isEmpty { pendingDuplicateAdds.removeFirst() }
    }

    func revealExistingDuplicate() {
        guard let pending = pendingDuplicateAdds.first else { return }
        pendingDuplicateAdds.removeFirst()
        revealInFinder(pending.match.existing)
    }

    private func uniqueFileName(base: String, inDirectory directory: String) -> String {
        func taken(_ name: String) -> Bool {
            downloads.contains { $0.destinationDirectoryPath == directory && $0.fileName == name }
                || FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(name))
        }
        guard taken(base) else { return base }
        let name = base as NSString
        let fileExtension = name.pathExtension
        let stem = name.deletingPathExtension
        var counter = 2
        while counter < 10_000 {
            let candidate = fileExtension.isEmpty
                ? "\(stem) (\(counter))"
                : "\(stem) (\(counter)).\(fileExtension)"
            if !taken(candidate) { return candidate }
            counter += 1
        }
        return base
    }

    @discardableResult
    func quickAdd(urlString: String, into directory: URL = AppEnvironment.defaultDownloadsDirectory()) -> Bool {
        guard let url = Self.normalizedURL(urlString) else { return false }
        add(DownloadRequest(url: url, destinationDirectoryPath: directory.path))
        return true
    }

    func extractPageLinks(from pageURL: URL, extensions: Set<String> = []) async -> [URL] {
        let maximumPageBytes = 10 * 1024 * 1024
        guard let data = try? await BoundedHTTPFetcher.get(
            pageURL,
            headers: ["Accept": "text/html,application/xhtml+xml"],
            maximumBytes: maximumPageBytes,
            requestTimeout: 20,
            resourceTimeout: 20,
            proxies: BrowserStore.shared.browsingProxyConfigurations
        ) else { return [] }
        let work = Task.detached(priority: .userInitiated) { () -> [URL] in
            guard !Task.isCancelled else { return [] }
            let html = String(bytes: data, encoding: .utf8)
                ?? String(bytes: data, encoding: .isoLatin1)
                ?? ""
            guard !Task.isCancelled else { return [] }
            let links = PageLinkExtractor.extract(
                html: html,
                baseURL: pageURL,
                extensions: extensions,
                maximumCount: URLBatch.expansionLimit
            )
            return Task.isCancelled ? [] : links
        }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    func addURLs(
        _ urls: [URL],
        into directory: URL = AppEnvironment.defaultDownloadsDirectory(),
        bookmark: Data? = nil
    ) {
        var requests: [DownloadRequest] = []
        requests.reserveCapacity(urls.count)
        for url in urls {
            let request = DownloadRequest(
                url: url,
                destinationDirectoryPath: directory.path,
                destinationBookmark: bookmark
            )
            if let match = duplicateMatch(for: request) {
                pendingDuplicateAdds.append(DuplicateAdd(request: request, match: match))
            } else {
                requests.append(request)
            }
        }
        guard !requests.isEmpty else { return }
        Task { [manager] in
            for request in requests { await manager.add(request) }
        }
    }

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

    func addDetectedClipboardURL() {
        guard let url = detectedClipboardURL else { return }
        pendingAddURL = url.absoluteString
        detectedClipboardURL = nil
        isAddSheetPresented = true
    }

    func dismissDetectedClipboardURL() {
        detectedClipboardURL = nil
    }

    // MARK: External capture

    func handleIncomingURL(_ url: URL) {
        guard isNetworkReady else {
            guard !pendingIncomingURLs.contains(url) else { return }
            if pendingIncomingURLs.count == Self.pendingIntakeLimit { pendingIncomingURLs.removeFirst() }
            pendingIncomingURLs.append(url)
            return
        }
        if url.isFileURL {
            if Self.isMetalink(url) { openMetalink(url) }
            return
        }
        guard url.scheme?.lowercased() == "cloakdrop",
              let capture = try? CapturedDownload.parse(cloakdropURL: url) else { return }
        enqueueCapture(capture)
    }

    func drainCaptureInbox() {
        for capture in CaptureInbox.drain() { enqueueCapture(capture) }
    }

    func enqueueCapture(_ capture: CapturedDownload) {
        guard isNetworkReady else {
            guard !pendingCaptures.contains(capture) else { return }
            if pendingCaptures.count == Self.pendingIntakeLimit { pendingCaptures.removeFirst() }
            pendingCaptures.append(capture)
            return
        }
        let request = capture.toRequest(destinationDirectoryPath: AppEnvironment.defaultDownloadsDirectory().path)
        if capture.extractFromPage == true {
            grabFromPage(capture)
        } else if let audioURL = capture.audioURL {
            grabPairedMedia(request, audioURL: audioURL)
        } else {
            grab(request)
        }
    }

    func presentMediaError(_ message: String) {
        mediaExtractionError = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if self?.mediaExtractionError == message { self?.mediaExtractionError = nil }
        }
    }

    // MARK: Catalog actions

    func pause(_ id: UUID) { Task { await manager.pause(id: id) } }
    func resume(_ id: UUID) { Task { await manager.resume(id: id) } }
    func remove(_ id: UUID, deleteFile: Bool) { Task { await manager.remove(id: id, deleteFile: deleteFile) } }
    func removeSelected(deleteFile: Bool) { selectedDownloadIDs.forEach { remove($0, deleteFile: deleteFile) } }
    func pauseAll() { Task { await manager.pauseAll() } }
    func resumeAll() { Task { await manager.resumeAll() } }
    func clearCompleted() { Task { await manager.clearCompleted() } }
    func refreshStats() { Task { await manager.reloadStats() } }
    func resetStats() { Task { await manager.resetStats() } }

    var hasCompleted: Bool { downloads.contains { $0.status == .completed } }

    func updateSettings(_ newSettings: EngineSettings) {
        settings = newSettings
        Task { await manager.updateSettings(newSettings) }
        BrowserStore.shared.applyProxy(newSettings.resolvedProxy)
    }

    // MARK: Rules and login

    var nextRuleOrder: Int { (rules.map(\.order).max() ?? -1) + 1 }

    func saveRule(_ rule: SmartRule) { Task { await manager.saveRule(rule) } }
    func deleteRule(_ id: UUID) { Task { await manager.deleteRule(id: id) } }

    func moveRules(fromOffsets source: IndexSet, toOffset destination: Int) {
        var reordered = rules
        reordered.move(fromOffsets: source, toOffset: destination)
        rules = reordered
        Task { await manager.reorderRules(reordered.map(\.id)) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        try? loginItem.setEnabled(enabled)
        if enabled, loginItem.needsApproval { loginItem.openSystemSettings() }
        launchAtLoginEnabled = loginItem.isEnabled
    }
}
