import AppKit
import DownloadModels
import DownloadEngine

/// Finder / system integration for a download — reveal in Finder, open with the default app, and
/// copy source URLs. Split out of `AppModel` (matching the other `AppModel+*` extensions) so the
/// core file stays focused.
extension AppModel {
    func revealInFinder(_ download: Download) {
        withResolvedFileURL(for: download) { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    }

    func open(_ download: Download) {
        withResolvedFileURL(for: download) { NSWorkspace.shared.open($0) }
    }

    /// Keep folder access alive while Finder receives the resolved path. A supplied bookmark must
    /// resolve to its original folder identity; never fall back to a replacement at the old path.
    private func withResolvedFileURL(for download: Download, perform action: (URL) -> Void) {
        let scope = SecurityScope(bookmark: download.destinationBookmark)
        let accessGranted = scope.start()
        defer { scope.stop() }
        let path: String
        if scope.hasBookmark {
            guard accessGranted, let resolved = scope.resolvedPath(for: download.destinationFilePath) else {
                raiseMainWindow?()
                presentMediaError(CocoaError(.fileReadNoPermission, userInfo: [
                    NSFilePathErrorKey: download.destinationDirectoryPath
                ]).localizedDescription)
                return
            }
            path = resolved
        } else {
            path = download.destinationFilePath
        }
        action(URL(fileURLWithPath: path))
    }

    /// Copy one or more source URLs (newline-separated) — used by the selection-aware row menu.
    func copyURLs(_ downloads: [Download]) {
        guard !downloads.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(downloads.map(\.url.absoluteString).joined(separator: "\n"), forType: .string)
    }
}
