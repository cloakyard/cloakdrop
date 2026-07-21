import SwiftUI
import DownloadModels

/// The menu-bar dropdown: live aggregate stats, the most recent active downloads, and
/// always-available pause-all / resume-all controls — IDM-style ambient access.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var active: [Download] {
        model.downloads.filter { $0.status == .downloading || $0.status == .queued }
    }

    var body: some View {
        if active.isEmpty {
            Text("No active downloads")
        } else {
            // Count as a string so the format key is "%@ downloading · %@" (matching the catalog).
            Text("\(String(model.activeCount)) downloading · \(Format.speed(model.aggregateSpeed))")
            Divider()
            ForEach(active.prefix(5)) { download in
                Button {
                    showMainWindow()
                } label: {
                    Text("\(Self.menuTitle(download.fileName)) — \(Format.percent(model.liveFraction(download)))")
                }
            }
        }

        Divider()
        Button("Pause All") { model.pauseAll() }
        Button("Resume All") { model.resumeAll() }
        Divider()
        Button("Open CloakDrop") { showMainWindow() }
        Button("Open Browser") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: BrowserScene.windowID)
        }
        Button("Speed Test…") {
            NSApp.activate(ignoringOtherApps: true)
            model.settingsSelection = .speedTest
            openSettings()
        }
        Button("Report a Bug…") { NSWorkspace.shared.open(BugReport.issueURL) }
        Button("Quit CloakDrop") { NSApp.terminate(nil) }
    }

    /// Middle-truncate a file name for a menu item — menus size to their widest row, so one long
    /// name would stretch the whole dropdown across the screen.
    private static func menuTitle(_ name: String, limit: Int = 40) -> String {
        guard name.count > limit else { return name }
        let keep = (limit - 1) / 2
        return "\(name.prefix(keep))…\(name.suffix(keep))"
    }

    /// Bring the app forward and reopen/raise the main window — works even if the user closed
    /// it while downloads keep running in the background.
    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: CloakDropApp.mainWindowID)
    }
}
