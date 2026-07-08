import AppKit
import DownloadModels

/// Finder / system integration for a download — reveal in Finder, open with the default app, and
/// copy source URLs. Split out of `AppModel` (matching the other `AppModel+*` extensions) so the
/// core file stays focused.
extension AppModel {
    func revealInFinder(_ download: Download) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: download.destinationFilePath)])
    }

    func open(_ download: Download) {
        NSWorkspace.shared.open(URL(fileURLWithPath: download.destinationFilePath))
    }

    /// Copy one or more source URLs (newline-separated) — used by the selection-aware row menu.
    func copyURLs(_ downloads: [Download]) {
        guard !downloads.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(downloads.map(\.url.absoluteString).joined(separator: "\n"), forType: .string)
    }
}
