import Foundation
import DownloadModels

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
