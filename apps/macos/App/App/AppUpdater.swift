import Combine
import Sparkle
import SwiftUI

/// App-lifetime owner. Update preferences belong to Sparkle, outside the app's domain store.
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var startupError: String?

    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        // Hosted unit tests must never inherit a user's automatic-update preference.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              ProcessInfo.processInfo.environment["CLOAKROLL_TESTING"] != "1" else { return }
        do {
            try controller.updater.start()
        } catch {
            startupError = error.localizedDescription
        }
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloads)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticDownloads(_ enabled: Bool) {
        controller.updater.automaticallyDownloadsUpdates = enabled
    }
}

struct UpdateCommands: Commands {
    @ObservedObject var updater: AppUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…", action: updater.checkForUpdates)
                .disabled(!updater.canCheckForUpdates)
        }
    }
}

struct UpdateSettingsSection: View {
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        Section {
            Button("Check for Updates…", action: updater.checkForUpdates)
                .disabled(!updater.canCheckForUpdates)
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updater.automaticallyChecks }, set: updater.setAutomaticChecks
            ))
            .disabled(updater.startupError != nil)
            Toggle("Download updates and install when quitting", isOn: Binding(
                get: { updater.automaticallyDownloads }, set: updater.setAutomaticDownloads
            ))
            .disabled(!updater.automaticallyChecks || updater.startupError != nil)
            if let error = updater.startupError {
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("""
            Checks contact this app’s Cloakyard website; downloads come from GitHub. \
            Automatic updates are optional. No analytics or system profile is sent.
            """)
        }
    }
}
