import SwiftUI
import DownloadModels

/// The Settings window's tabs. Held as app state so a menu command (e.g. "About CloakDrop")
/// can open Settings directly to a specific tab.
enum SettingsTab: Hashable {
    case general, rules, network, browsers, privacy, about
}

/// Preferences: engine tunables, CloakDrop's privacy posture, and app/author info.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsSelection) {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            RulesSettingsView()
                .tabItem { Label("Rules", systemImage: "arrow.triangle.branch") }
                .tag(SettingsTab.rules)
            network
                .tabItem { Label("Network", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(SettingsTab.network)
            BrowsersSettingsView()
                .tabItem { Label("Browsers", systemImage: "globe") }
                .tag(SettingsTab.browsers)
            privacy
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
                .tag(SettingsTab.privacy)
            about
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 480, height: 500)
        // Settings always reopens on the first page (General); About is reached via its own
        // "About CloakDrop" command, which sets the tab just before opening the window. Reset
        // on close so a later plain ⌘, doesn't reopen on whatever tab was last viewed.
        .onDisappear { model.settingsSelection = .general }
    }

    // MARK: General

    private var general: some View {
        Form {
            Section {
                Stepper(value: binding(\.defaultSegmentCount), in: 1...model.settings.maxSegmentCount) {
                    LabeledContent("Default connections", value: "\(model.settings.defaultSegmentCount)")
                }
                Stepper(value: binding(\.maxSegmentCount), in: 1...32) {
                    LabeledContent("Maximum connections", value: "\(model.settings.maxSegmentCount)")
                }
            } header: {
                Text("Connections")
            } footer: {
                Text("Files download in parallel segments. More connections can be faster on high-latency links.")
            }

            Section {
                Toggle("Verify checksums automatically", isOn: binding(\.verifyChecksumsAutomatically))
                Toggle("Look for checksum files on the server", isOn: binding(\.autoDiscoverChecksums))
                    .disabled(!model.settings.verifyChecksumsAutomatically)
                Toggle("Check app signatures", isOn: binding(\.assessSignatures))
                Toggle("Sort completed files into type folders", isOn: binding(\.autoCategorize))
            } header: {
                Text("On Completion")
            } footer: {
                Text("Also checks a checksum the site publishes next to the download on the same server (.sha256/.sha1/.md5).")
            }

            Section {
                Toggle("Limit download speed", isOn: speedLimitEnabled)
                if model.settings.globalSpeedLimitBytesPerSecond != nil {
                    HStack {
                        Text("Maximum")
                        Spacer()
                        TextField("5", value: speedLimitMBs, format: .number)
                            .labelsHidden()
                            .frame(width: 70)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            // `.labelsHidden()` drops the field's VoiceOver label; restore it (the
                            // visible "Maximum" / "MB/s" text around it is a separate element).
                            .accessibilityLabel("Maximum")
                        Text("MB/s").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Speed")
            } footer: {
                Text("Applies across all active downloads combined.")
            }

            Section("Capture") {
                Toggle("Watch clipboard for links", isOn: Binding(
                    get: { model.clipboardMonitoringEnabled },
                    set: { model.clipboardMonitoringEnabled = $0 }
                ))
            }

            Section("Reliability") {
                Stepper(value: binding(\.maxRetryAttempts), in: 0...20) {
                    LabeledContent("Retry attempts", value: "\(model.settings.maxRetryAttempts)")
                }
            }

            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Picker("Interrupted downloads", selection: binding(\.resumeDownloadsOnLaunch)) {
                    Text("Resume on launch").tag(true)
                    Text("Keep paused").tag(false)
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("Open CloakDrop automatically when you log in.")
            }

            Section("When Finished") {
                Picker("After all downloads finish", selection: postActionBinding) {
                    ForEach(SchedulerPostAction.allCases) { Text($0.localizedLabel).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: Network

    private var network: some View {
        Form {
            Section {
                Picker("Connection", selection: proxyBinding(\.mode)) {
                    ForEach(ProxyConfiguration.Mode.allCases) { Text($0.localizedLabel).tag($0) }
                }
            } header: {
                Text("Proxy")
            } footer: {
                Text("A proxy is the only connection CloakDrop makes beyond the URLs you download.")
            }

            if model.settings.resolvedProxy.mode == .manual {
                Section("Manual Proxy") {
                    Picker("Type", selection: proxyBinding(\.type)) {
                        ForEach(ProxyConfiguration.ProxyType.allCases) { Text($0.label).tag($0) }
                    }
                    TextField("Host", text: proxyBinding(\.host), prompt: Text("proxy.example.com"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Port", value: proxyBinding(\.port), format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                    TextField("Username", text: proxyBinding(\.username), prompt: Text("Optional"))
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password", text: proxyBinding(\.password), prompt: Text("Optional"))
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        .formStyle(.grouped)
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: Privacy

    private var privacy: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 46))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .padding(.top, 8)

            Text("Private by design")
                .font(.title2.weight(.semibold))

            Text("CloakDrop is part of the Cloakyard privacy-first suite.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 14) {
                guarantee("Everything runs on-device")
                guarantee("No accounts, analytics, or telemetry")
                guarantee("Network access only to the URLs you download")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

            Text("CloakDrop never phones home. Your download history and settings stay on this Mac, fully under your control.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func guarantee(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Text(text)
            Spacer(minLength: 0)
        }
    }

    // MARK: About

    private var about: some View {
        VStack(spacing: 14) {
            // A dedicated asset, not `NSApp.applicationIconImage`: the latter is served from
            // macOS's icon cache, which can lag a rebuilt icon (showing a stale version). This
            // loads the exact shipped artwork straight from the catalog.
            Image("AboutAppIcon")
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .padding(.top, 4)

            VStack(spacing: 3) {
                Text(verbatim: "CloakDrop")
                    .font(.title2.weight(.semibold))
                Text("Version \(Self.appVersion)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Created by Sumit Sahoo")
                .font(.callout)

            VStack(spacing: 2) {
                linkRow(symbol: "person.crop.circle", label: Text(verbatim: "github.com/sumitsahoo"), url: AppLinks.author)
                Divider()
                linkRow(
                    symbol: "chevron.left.forwardslash.chevron.right",
                    label: Text(verbatim: "github.com/cloakyard/cloakdrop"),
                    url: AppLinks.repository
                )
                Divider()
                linkRow(symbol: "ladybug", label: Text("Report a Bug"), url: AppLinks.reportBug)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A tappable row that opens `url` in the default browser (native `Link`), styled to read
    /// as a list entry with a leading glyph and a trailing "opens externally" affordance.
    private func linkRow(symbol: String, label: Text, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                label
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.forward")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    /// "1.0 (1)" — short version plus build, read from the bundle.
    private static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    // MARK: Binding helpers

    private func binding<Value>(_ keyPath: WritableKeyPath<EngineSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in
                var settings = model.settings
                settings[keyPath: keyPath] = newValue
                model.updateSettings(settings)
            }
        )
    }

    private var postActionBinding: Binding<SchedulerPostAction> {
        Binding(
            get: { model.settings.resolvedPostAction },
            set: { newValue in
                var settings = model.settings
                settings.postCompletionAction = newValue
                model.updateSettings(settings)
            }
        )
    }

    private func proxyBinding<Value>(_ keyPath: WritableKeyPath<ProxyConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings.resolvedProxy[keyPath: keyPath] },
            set: { newValue in
                var settings = model.settings
                var proxy = settings.resolvedProxy
                proxy[keyPath: keyPath] = newValue
                settings.proxy = proxy
                model.updateSettings(settings)
            }
        )
    }

    private var speedLimitEnabled: Binding<Bool> {
        Binding(
            get: { model.settings.globalSpeedLimitBytesPerSecond != nil },
            set: { on in
                var settings = model.settings
                settings.globalSpeedLimitBytesPerSecond = on ? 5_000_000 : nil
                model.updateSettings(settings)
            }
        )
    }

    private var speedLimitMBs: Binding<Double> {
        Binding(
            get: { Double(model.settings.globalSpeedLimitBytesPerSecond ?? 0) / 1_000_000 },
            set: { mb in
                var settings = model.settings
                settings.globalSpeedLimitBytesPerSecond = Int64(max(0.1, mb) * 1_000_000)
                model.updateSettings(settings)
            }
        )
    }
}
