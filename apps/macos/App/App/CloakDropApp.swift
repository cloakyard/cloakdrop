import SwiftUI
import AppKit

/// CloakDrop — a native, private, multi-segment download manager for macOS.
/// Part of the Cloakyard privacy-first suite. Everything runs on-device.
@main
struct CloakDropApp: App {
    /// Scene id for the single main window, shared with the menu bar's "Open CloakDrop".
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel?
    @State private var startupError: String?

    init() {
        do {
            _model = State(initialValue: try Self.makeModel())
        } catch {
            _startupError = State(initialValue: error.localizedDescription)
        }
    }

    private static func makeModel() throws -> AppModel {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--verify-dark-appearance") {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
        // Exercise the recovery UI without altering the real catalog.
        if ProcessInfo.processInfo.arguments.contains("--verify-store-unavailable") {
            throw CocoaError(.fileReadCorruptFile)
        }
        if ProcessInfo.processInfo.arguments.contains("--hero-fixture") { return try AppModel.heroFixture() }
        #endif
        return try AppModel.live()
    }

    private func retryStartup() {
        do {
            model = try Self.makeModel()
            startupError = nil
        } catch {
            startupError = error.localizedDescription
        }
    }

    /// A failed store open leaves the catalog untouched and every network-capable scene unavailable.
    /// Retrying constructs a fresh model only after the persistent store opens successfully.
    private var startupFailure: some View {
        ContentUnavailableView {
            Label("Startup", systemImage: "exclamationmark.triangle")
        } description: {
            Text(startupError ?? "")
        } actions: {
            Button("Try Again", action: retryStartup)
            Button("Quit CloakDrop") { NSApp.terminate(nil) }
        }
    }

    var body: some Scene {
        // A single main window (not a WindowGroup): the menu-bar "Open CloakDrop" can then
        // reopen it when closed — or bring it forward when already open — instead of spawning
        // duplicate windows. A download manager has no need for multiple main windows.
        Window("CloakDrop", id: Self.mainWindowID) {
            Group {
                if let model {
                    RootView()
                        .environment(model)
                        .background(CaptureIntakeInstaller(model: model, appDelegate: appDelegate))
                        .task { await model.bootstrap() }
                } else {
                    startupFailure
                }
            }
            .frame(minWidth: 860, minHeight: 520)
        }
        .commands { if let model { CloakDropCommands(model: model) } }

        BrowserScene(model: model)

        MenuBarExtra("CloakDrop", systemImage: "arrow.down.circle") {
            if let model {
                MenuBarContent().environment(model)
            } else {
                Button("Try Again", action: retryStartup)
                Button("Quit CloakDrop") { NSApp.terminate(nil) }
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            if let model {
                SettingsView().environment(model)
            } else {
                startupFailure
            }
        }
    }
}

/// App-wide menu commands and keyboard shortcuts.
struct CloakDropCommands: Commands {
    let model: AppModel
    /// SwiftUI's official action to open the Settings scene (macOS 14+) — reliable, unlike
    /// poking `showSettingsWindow:` down the responder chain.
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // App info lives in Settings ▸ About (there's no separate About panel), so route the
        // standard "About CloakDrop" item there, pre-selecting the About tab.
        CommandGroup(replacing: .appInfo) {
            Button("About CloakDrop") {
                model.settingsSelection = .about
                openSettings()
            }
            Button("Download Stats…") {
                model.settingsSelection = .stats
                openSettings()
            }
            Button("Speed Test…") {
                model.settingsSelection = .speedTest
                openSettings()
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Download…") { model.isAddSheetPresented = true }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!model.isNetworkReady)
            Button("New Browser Window") { openWindow(id: BrowserScene.windowID) }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(!model.isNetworkReady)
            Button("Open Metalink…") { model.importMetalink() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!model.isNetworkReady)
        }
        CommandMenu("Downloads") {
            Button("Pause All") { model.pauseAll() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!model.isNetworkReady)
            Button("Resume All") { model.resumeAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.isNetworkReady)
            Divider()
            Button("Clear Completed") { model.clearCompleted() }
                .disabled(!model.isNetworkReady || !model.hasCompleted)
        }
        // The macOS-standard home for "Report a Bug" is the Help menu; also mirrored in the
        // menu-bar extra for one-click access while the main window is closed.
        CommandGroup(replacing: .help) {
            Button("Report a Bug…") { NSWorkspace.shared.open(BugReport.issueURL) }
        }
    }
}

/// Delivers `cloakdrop://` opens to the app even when the main window is closed (it keeps running
/// via the menu-bar extra). SwiftUI's `.onOpenURL` only fires while a window hosting it is alive,
/// so capture links route through the AppKit delegate instead.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let pendingURLLimit = 128
    private var openURLsHandler: (([URL]) -> Void)?
    private var pendingURLs: [URL] = []
    /// `NSApplication` doesn't retain `servicesProvider`, so we hold it here for the app's lifetime.
    var servicesProvider: ServicesProvider?
    var reopenMainWindow: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A browser or Settings window can be visible while the downloads window is closed.
        // Dock activation must still reopen the downloads window, including during transfers.
        guard let reopenMainWindow else { return true }
        reopenMainWindow()
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let openURLsHandler else {
            for url in urls where !pendingURLs.contains(url) {
                if pendingURLs.count == Self.pendingURLLimit { pendingURLs.removeFirst() }
                pendingURLs.append(url)
            }
            return
        }
        openURLsHandler(urls)
    }

    /// Installs the live handler and drains cold-launch URLs exactly once. Delegate callbacks and
    /// this setter are main-actor isolated, so clearing before delivery makes the handoff atomic.
    func installOpenURLsHandler(_ handler: @escaping ([URL]) -> Void) {
        openURLsHandler = handler
        guard !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs.removeAll()
        handler(urls)
    }
}

/// Installs the URL handler once the app is up, capturing `openWindow` so an incoming capture can
/// raise the main window (reopening it if the user had closed it) before the confirm banner shows.
/// Rendered as a zero-size background of the main scene.
private struct CaptureIntakeInstaller: View {
    let model: AppModel
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .onAppear {
                let showMainWindow = {
                    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == CloakDropApp.mainWindowID }) {
                        if window.isMiniaturized { window.deminiaturize(nil) }
                        window.makeKeyAndOrderFront(nil)
                    } else {
                        openWindow(id: CloakDropApp.mainWindowID)
                    }
                    NSApp.activate()
                }
                appDelegate.reopenMainWindow = showMainWindow
                appDelegate.installOpenURLsHandler { urls in
                    showMainWindow()
                    for url in urls { model.handleIncomingURL(url) }
                }
                // Lets browser windows summon the main window (quality picker, duplicate prompts).
                model.raiseMainWindow = showMainWindow
                // Register the "Send to CloakDrop" Services item. NSApp doesn't retain the provider,
                // so the delegate holds it; NSUpdateDynamicServices refreshes the system registration.
                let provider = ServicesProvider(model: model)
                appDelegate.servicesProvider = provider
                NSApp.servicesProvider = provider
                NSUpdateDynamicServices()
            }
    }
}
