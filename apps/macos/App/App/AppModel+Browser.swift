import Foundation
import DownloadModels

// MARK: - Ad-blocker blocklists

extension AppModel {
    /// The chosen source changed: activate its stored copy, refresh open windows, and — for a list
    /// never downloaded before — fetch it now (the pick itself is the required user action).
    func blocklistSourceChanged() {
        blocklistInfo = nil
        blocklistUpdateError = nil
        replaceBlocklistTask(for: browserBlocklistSource, update: .ifMissing)
    }

    /// The Settings "Update Now" action.
    func updateBlocklistNow() {
        guard browserBlocklistSource != .builtIn else { return }
        replaceBlocklistTask(for: browserBlocklistSource, update: .always)
    }

    private func replaceBlocklistTask(for source: BlocklistSource, update: BlocklistUpdatePolicy) {
        blocklistTask?.cancel()
        blocklistTaskGeneration &+= 1
        let generation = blocklistTaskGeneration
        isUpdatingBlocklist = update == .always && source != .builtIn
        blocklistTask = Task { [weak self] in
            await self?.runBlocklistTask(for: source, update: update, generation: generation)
        }
    }

    private func runBlocklistTask(
        for source: BlocklistSource,
        update: BlocklistUpdatePolicy,
        generation: Int
    ) async {
        defer { finishBlocklistTask(generation: generation) }
        do {
            try Task.checkCancellation()
            let shouldActivate = update == .ifMissing || BrowserStore.shared.activeBlocklistSource != source
            if shouldActivate {
                await BrowserStore.shared.activateBlocklist(source)
                try Task.checkCancellation()
                guard isCurrentBlocklistTask(source: source, generation: generation) else { return }
                blocklistInfo = BrowserStore.shared.externalInfo
                browserContentRulesGeneration &+= 1
            }

            let shouldUpdate = source != .builtIn
                && (update == .always || BrowserStore.shared.externalInfo == nil)
            guard shouldUpdate, isCurrentBlocklistTask(source: source, generation: generation) else { return }
            isUpdatingBlocklist = true
            blocklistUpdateError = nil
            let info = try await BrowserStore.shared.updateBlocklist(for: source)
            try Task.checkCancellation()
            guard isCurrentBlocklistTask(source: source, generation: generation) else { return }
            blocklistInfo = info
            browserContentRulesGeneration &+= 1
        } catch is CancellationError {
            // A source switch or replacement owns the UI now.
        } catch {
            if isCurrentBlocklistTask(source: source, generation: generation) {
                blocklistUpdateError = error.localizedDescription
            }
        }
    }

    private func isCurrentBlocklistTask(source: BlocklistSource, generation: Int) -> Bool {
        !Task.isCancelled && blocklistTaskGeneration == generation && browserBlocklistSource == source
    }

    private func finishBlocklistTask(generation: Int) {
        guard blocklistTaskGeneration == generation else { return }
        isUpdatingBlocklist = false
        blocklistTask = nil
    }

    /// Warm the curated compile and activate the *stored* copy of the chosen list (no network),
    /// then nudge open browser windows. Runs at launch (when blocking is on) and on enable.
    func prepareContentBlocking() {
        Task { [weak self, source = browserBlocklistSource] in
            guard let self else { return }
            _ = await BrowserStore.shared.adBlockRuleList()
            guard !Task.isCancelled, self.browserBlocklistSource == source else { return }
            // A user-selected source pipeline owns activation and eviction while it is running.
            // Avoid racing its WebKit compile, but still expose the newly ready curated rules.
            if self.blocklistTask != nil {
                self.browserContentRulesGeneration &+= 1
                return
            }
            await BrowserStore.shared.activateBlocklist(source)
            guard !Task.isCancelled, self.browserBlocklistSource == source, self.blocklistTask == nil else { return }
            await BrowserStore.shared.evictStaleCompiledLists()
            guard !Task.isCancelled, self.browserBlocklistSource == source, self.blocklistTask == nil else { return }
            self.blocklistInfo = BrowserStore.shared.externalInfo
            self.browserContentRulesGeneration &+= 1
        }
    }
}

private enum BlocklistUpdatePolicy: Equatable {
    case ifMissing
    case always
}

/// The app side of the in-app browser: routes browser captures into the same grab/add funnels as
/// every other intake, with one deliberate difference — **browser grabs always offer the quality
/// picker** when there is a real choice, because the user is right there choosing what to save.
extension AppModel: BrowserCaptureSink {
    var canExtractFromPages: Bool { mediaExtractor != nil }

    func browserCapture(_ capture: CapturedDownload, kind: SniffedItem.ItemType, cookiesFile: URL?) {
        // FTP(S) links clicked in the browser: the engine speaks FTP natively; the http(s)-only
        // capture validation is for *untrusted* intake and doesn't apply to our own browser.
        if let scheme = capture.url.scheme?.lowercased(), scheme == "ftp" || scheme == "ftps" {
            quickAdd(urlString: capture.url.absoluteString)
            return
        }
        guard let validated = try? capture.validated() else {
            if let cookiesFile { try? FileManager.default.removeItem(at: cookiesFile) }
            return
        }
        let request = validated.toRequest(destinationDirectoryPath: AppEnvironment.defaultDownloadsDirectory().path)
        switch kind {
        case .page:
            raiseMainWindow?()   // the quality picker presents from the main window
            grabFromPage(validated, cookiesFile: cookiesFile, forcePicker: true)
        case .stream:
            raiseMainWindow?()
            grabStream(request, forcePicker: true)
        case .video, .audio, .file:
            grab(request)   // a `.m3u8`/`.mpd` URL still reroutes into the media flow by extension
        }
    }
}
