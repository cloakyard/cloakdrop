import SwiftUI
import SafariServices

/// Settings ▸ Browsers — turn on the capture integration for each browser.
///
/// Safari's extension is bundled and toggled inside Safari itself; the Chromium browsers and Firefox
/// need a small native-messaging connector, which `NativeMessagingInstaller` writes after the user
/// grants access to that browser's folder. The extension itself is loaded separately (see
/// `BrowserExtension/README.md`).
struct BrowsersSettingsView: View {
    @State private var installer = NativeMessagingInstaller()
    @State private var installError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Open Safari Settings…") { openSafariExtensionPreferences() }
                } label: {
                    Label("Safari", systemImage: "safari")
                }
            } header: {
                Text("Safari")
            } footer: {
                Text("Bundled with CloakDrop. Turn it on in Safari ▸ Settings ▸ Extensions, then right-click a link to send it here.")
            }

            Section {
                if installer.isHostAvailable {
                    ForEach(NativeMessagingInstaller.Browser.allCases) { browser in
                        browserRow(browser)
                    }
                } else {
                    Label("The browser connector is unavailable in this build.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Chrome, Edge, Brave & Firefox")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Installs a small on-device connector so these browsers can hand downloads to CloakDrop.")
                    Text("You’ll grant access to each browser’s folder, then add the CloakDrop extension. Everything stays on this Mac.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollBounceBehavior(.basedOnSize)
        .alert(
            "Couldn’t Enable Integration",
            isPresented: Binding(get: { installError != nil }, set: { if !$0 { installError = nil } }),
            presenting: installError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { detail in
            Text(detail)
        }
    }

    @ViewBuilder
    private func browserRow(_ browser: NativeMessagingInstaller.Browser) -> some View {
        LabeledContent {
            if installer.isInstalled(browser) {
                HStack(spacing: 12) {
                    Label("Enabled", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                        .font(.callout)
                    Button("Remove") { installer.uninstall(browser) }
                }
            } else {
                Button("Enable…") { enable(browser) }
            }
        } label: {
            Text(browser.displayName)
        }
    }

    private func enable(_ browser: NativeMessagingInstaller.Browser) {
        do {
            _ = try installer.install(browser)
        } catch {
            installError = error.localizedDescription
        }
    }

    /// Deep-link into Safari's per-extension settings, so the user lands exactly where they enable it.
    private func openSafariExtensionPreferences() {
        SFSafariApplication.showPreferencesForExtension(
            withIdentifier: "com.cloakyard.cloakdrop.SafariExtension"
        ) { _ in }
    }
}
