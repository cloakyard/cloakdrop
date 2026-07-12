import SwiftUI

/// Identity for one browser window. A fresh `id` per open makes every request a NEW window —
/// value-presented `WindowGroup`s otherwise dedupe by value (opening the same URL twice would
/// focus the first window instead of opening a second).
struct BrowserLaunch: Codable, Hashable {
    var id = UUID()
    var url: URL?
    /// Windows the page itself opened (popups) may auto-close when their only act is a download.
    var openedByPage = false
}

/// The built-in browser: as many windows as the user likes, natively tabbable
/// (`BrowserWindowConfigurator` opts them into macOS window tabbing).
struct BrowserScene: Scene {
    static let windowID = "browser"
    let model: AppModel

    var body: some Scene {
        WindowGroup(id: Self.windowID, for: BrowserLaunch.self) { $launch in
            BrowserView(launch: launch)
                .environment(model)
        } defaultValue: {
            BrowserLaunch()
        }
        .commands { BrowserCommands() }
    }
}

/// Browser menu commands — enabled only while a browser window is focused.
struct BrowserCommands: Commands {
    @FocusedValue(\.browserSession) private var session

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Open Location…") { session?.focusURLBar() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(session == nil)
            Button("Reload Page") { session?.reloadOrStop() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(session == nil)
            Divider()
            Button("Actual Size") { session?.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(session == nil)
            Button("Zoom In") { session?.zoom(by: 1.1) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(session == nil)
            Button("Zoom Out") { session?.zoom(by: 1.0 / 1.1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(session == nil)
        }
    }
}

extension FocusedValues {
    /// The focused browser window's session, for menu commands (⌘L, ⌘R, zoom).
    @Entry var browserSession: BrowserSession?
}
