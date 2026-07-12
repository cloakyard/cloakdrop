import Foundation
import DownloadModels

/// System-capture intake — links handed to CloakDrop by macOS itself rather than a browser: the
/// Services menu ("Send to CloakDrop", see `ServicesProvider`) and the share sheet's in-process
/// path. Both surface the link through the same confirm banner every other capture uses, so nothing
/// is ever queued silently.
extension AppModel {
    /// Enqueue http/https URLs captured from the system for confirmation. Non-web URLs are dropped;
    /// each survivor is validated (the shared `CapturedDownload` bounds) before it reaches the UI.
    func captureSystemURLs(_ urls: [URL]) {
        for url in urls where url.scheme == "http" || url.scheme == "https" {
            guard let capture = try? CapturedDownload(url: url, source: .services).validated() else { continue }
            enqueueCapture(capture)
        }
    }
}
