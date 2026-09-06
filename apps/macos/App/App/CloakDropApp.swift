import SwiftUI
import AppKit

/// CloakDrop — a native, private, multi-segment download manager for macOS.
/// Part of the Cloakyard privacy-first suite. Everything runs on-device.
@main
struct CloakDropApp: App {
    /// Scene id for the single main window, shared with the menu bar's "Open CloakDrop".
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        do {
            #if DEBUG
            // Exercise native dark materials without changing the user's system appearance.
            if ProcessInfo.processInfo.arguments.contains("--verify-dark-appearance") {
                NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            }
            let appModel = ProcessInfo.processInfo.arguments.contains("--hero-fixture")
                ? try AppModel.heroFixture()
                : try AppModel.live()
            #else
            let appModel = try AppModel.live()
            #endif
            _model = State(initialValue: appModel)
        } catch {
            // The only failure here is being unable to open the local database; there's no
            // safe way to continue without persistence, so fail fast with a clear message.
            fatalError("CloakDrop could not open its local store: \(error)")
        }
    }

    var body: some Scene {
        // A single main window (not a WindowGroup): the menu-bar "Open CloakDrop" can then
        // reopen it when closed — or bring it forward when already open — instead of spawning
        // duplicate windows. A download manager has no need for multiple main windows.
        Window("CloakDrop", id: Self.mainWindowID) {
            RootView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 520)
                .background(CaptureIntakeInstaller(model: model, appDelegate: appDelegate))
                .task { await model.bootstrap() }
        }
        .commands { CloakDropCommands(model: model) }

        BrowserScene(model: model)

        MenuBarExtra("CloakDrop", systemImage: "arrow.down.circle") {
            MenuBarContent()
                .environment(model)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(model)
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
                appDelegate.installOpenURLsHandler { urls in
                    NSApp.activate()
                    openWindow(id: CloakDropApp.mainWindowID)
                    for url in urls { model.handleIncomingURL(url) }
                }
                // Lets browser windows summon the main window (quality picker, duplicate prompts).
                model.raiseMainWindow = {
                    NSApp.activate()
                    openWindow(id: CloakDropApp.mainWindowID)
                }
                // Register the "Send to CloakDrop" Services item. NSApp doesn't retain the provider,
                // so the delegate holds it; NSUpdateDynamicServices refreshes the system registration.
                let provider = ServicesProvider(model: model)
                appDelegate.servicesProvider = provider
                NSApp.servicesProvider = provider
                NSUpdateDynamicServices()
            }
    }
}
