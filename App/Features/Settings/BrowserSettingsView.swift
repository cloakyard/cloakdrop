import SwiftUI

/// Settings ▸ Browser — the built-in browser's privacy controls. Logins (cookies/site data)
/// persist so you stay signed in; browsing *history* is never stored anywhere; and one button
/// wipes it all.
struct BrowserSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isClearing = false
    @State private var confirmClear = false
    @State private var didClear = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Search from the address bar", isOn: $model.browserSearchEnabled)
            } header: {
                Text("Address Bar")
            } footer: {
                Text(addressBarFooter)
            }

            Section {
                LabeledContent {
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        if isClearing {
                            ProgressView().controlSize(.small)
                        } else if didClear {
                            Label("Cleared", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Text("Clear Browsing Data…")
                        }
                    }
                    .disabled(isClearing)
                } label: {
                    Label("Cookies & Site Data", systemImage: "trash")
                }
            } header: {
                Text("Browsing Data")
            } footer: {
                // swiftlint:disable:next line_length
                Text("Cookies and site data keep you signed in to sites between launches. Clearing them signs you out everywhere and removes all cached site data. CloakDrop never records your browsing history.")
            }
        }
        .formStyle(.grouped)
        .scrollBounceBehavior(.basedOnSize)
        .confirmationDialog(
            "Clear all browsing data?",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Clear Browsing Data", role: .destructive) { clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // swiftlint:disable:next line_length
            Text("This signs you out of every site in the built-in browser and removes all cookies and cached site data. It can’t be undone.")
        }
    }

    private var addressBarFooter: LocalizedStringKey {
        model.browserSearchEnabled
            // swiftlint:disable:next line_length
            ? "Text that isn’t a web address is searched on DuckDuckGo when you press Return. Nothing is sent as you type — there are no search suggestions."
            // swiftlint:disable:next line_length
            : "Off: the address bar never searches, so nothing you type is ever sent to a search engine. Non-address text is opened as an https:// address."
    }

    private func clear() {
        isClearing = true
        didClear = false
        Task {
            await BrowserStore.shared.clearBrowsingData()
            isClearing = false
            didClear = true
        }
    }
}
