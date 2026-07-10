import SwiftUI
import DownloadModels

extension BlocklistSource {
    /// Picker label. The list names are proper nouns, shown verbatim in every locale.
    var displayName: String {
        switch self {
        case .builtIn: String(localized: "Built-in (Curated)", comment: "Blocklist choice: the app's own curated list")
        case .oisdSmall: "OISD Small"
        case .stevenBlack: "StevenBlack Hosts"
        case .peterLowe: "Peter Lowe’s List"
        }
    }
}

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
                if model.browserSearchEnabled {
                    Picker("Search Engine", selection: $model.browserSearchEngine) {
                        ForEach(SearchEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                }
            } header: {
                Text("Address Bar")
            } footer: {
                Text(addressBarFooter)
            }

            Section {
                Toggle("Block Ads & Trackers", isOn: $model.browserAdBlockEnabled)
                if model.browserAdBlockEnabled {
                    Picker("Blocklist", selection: $model.browserBlocklistSource) {
                        ForEach(BlocklistSource.allCases) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    if model.browserBlocklistSource != .builtIn {
                        blocklistUpdateRow
                    }
                }
            } header: {
                Text("Content Blocking")
            } footer: {
                Text(contentBlockingFooter)
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

    /// Status + Update for the chosen downloadable list: domain count and freshness on the left,
    /// the one explicit fetch action on the right.
    private var blocklistUpdateRow: some View {
        LabeledContent {
            Button {
                model.updateBlocklistNow()
            } label: {
                if model.isUpdatingBlocklist {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Update Now")
                }
            }
            .disabled(model.isUpdatingBlocklist)
        } label: {
            Text("List Status")
            if let error = model.blocklistUpdateError {
                Text(error).foregroundStyle(.red)
            } else if model.isUpdatingBlocklist {
                Text("Downloading the latest list…")
            } else if let info = model.blocklistInfo {
                let count = info.domainCount.formatted(.number)
                let when = info.updatedAt.formatted(.relative(presentation: .named))
                Text("\(count) domains · updated \(when)")
            } else {
                Text("Not downloaded yet")
            }
        }
    }

    private var contentBlockingFooter: LocalizedStringKey {
        guard model.browserAdBlockEnabled, model.browserBlocklistSource != .builtIn,
              let host = model.browserBlocklistSource.updateURL?.host() else {
            // swiftlint:disable:next line_length
            return "Off by default. When on, the built-in browser blocks ads, tracking scripts, and ad pop-ups on nearly every site — pages load faster and cleaner. Blocking happens entirely on your Mac, and never affects your downloads. If a site misbehaves, turn this off."
        }
        // swiftlint:disable:next line_length
        return "\(model.browserBlocklistSource.displayName) is an open-source blocklist layered on top of the built-in one. It is fetched from \(host) only when you choose it or press Update Now — never automatically. Blocking still happens entirely on your Mac and never affects your downloads."
    }

    private var addressBarFooter: LocalizedStringKey {
        model.browserSearchEnabled
            // swiftlint:disable:next line_length
            ? "Text that isn’t a web address is searched on \(model.browserSearchEngine.displayName) when you press Return. Nothing is sent as you type — there are no search suggestions."
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
