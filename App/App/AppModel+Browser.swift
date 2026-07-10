import Foundation
import DownloadModels

// MARK: - Ad-blocker blocklists

extension AppModel {
    /// The chosen source changed: activate its stored copy, refresh open windows, and — for a list
    /// never downloaded before — fetch it now (the pick itself is the required user action).
    func blocklistSourceChanged() {
        blocklistUpdateError = nil
        Task { [source = browserBlocklistSource] in
            await BrowserStore.shared.activateBlocklist(source)
            guard browserBlocklistSource == source else { return }
            blocklistInfo = BrowserStore.shared.externalInfo
            browserContentRulesGeneration += 1
            if source != .builtIn, BrowserStore.shared.externalInfo == nil {
                await runBlocklistUpdate()
            }
        }
    }

    /// The Settings "Update Now" action.
    func updateBlocklistNow() {
        Task { await runBlocklistUpdate() }
    }

    private func runBlocklistUpdate() async {
        let source = browserBlocklistSource
        guard source != .builtIn, !isUpdatingBlocklist else { return }
        isUpdatingBlocklist = true
        blocklistUpdateError = nil
        do {
            let info = try await BrowserStore.shared.updateBlocklist(for: source)
            if browserBlocklistSource == source {
                blocklistInfo = info
                browserContentRulesGeneration += 1
            }
        } catch {
            if browserBlocklistSource == source {
                blocklistUpdateError = error.localizedDescription
            }
        }
        isUpdatingBlocklist = false
    }

    /// Warm the curated compile and activate the *stored* copy of the chosen list (no network),
    /// then nudge open browser windows. Runs at launch (when blocking is on) and on enable.
    func prepareContentBlocking() {
        Task { [source = browserBlocklistSource] in
            _ = await BrowserStore.shared.adBlockRuleList()
            await BrowserStore.shared.activateBlocklist(source)
            await BrowserStore.shared.evictStaleCompiledLists()
            blocklistInfo = BrowserStore.shared.externalInfo
            browserContentRulesGeneration += 1
        }
    }
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
