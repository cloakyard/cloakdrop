import SwiftUI
import DownloadModels

/// The Settings window's tabs. Held as app state so a menu command (e.g. "About CloakDrop")
/// can open Settings directly to a specific tab.
enum SettingsTab: Hashable {
    case general, rules, network, speedTest, browser, privacy, stats, about
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
            SpeedTestSettingsView()
                .tabItem { Label("Speed Test", systemImage: "gauge.with.needle") }
                .tag(SettingsTab.speedTest)
            BrowserSettingsView()
                .tabItem { Label("Browser", systemImage: "globe") }
                .tag(SettingsTab.browser)
            StatsSettingsView()
                .tabItem { Label("Stats", systemImage: "medal") }
                .tag(SettingsTab.stats)
            PrivacySettingsView()
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
                .tag(SettingsTab.privacy)
            about
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        // Wide enough for all eight tab buttons (narrower overflows into a "»" menu) and tall
        // enough that the Speed Test dials fit without scrolling.
        .frame(width: 640, height: 600)
        .disabled(!model.isNetworkReady)
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
                Text("Automatic mode uses the default for ordinary files and adds connections for very large files, up to the maximum.")
            }

            Section {
                Toggle("Verify checksums automatically", isOn: binding(\.verifyChecksumsAutomatically))
                Toggle("Look for checksum files on the server", isOn: binding(\.autoDiscoverChecksums))
                    .disabled(!model.settings.verifyChecksumsAutomatically)
                Toggle("Check app signatures", isOn: binding(\.assessSignatures))
                Toggle("Flag files as downloaded (Gatekeeper check)", isOn: binding(\.applyQuarantine))
                Toggle("Create a provenance receipt", isOn: binding(\.generateProvenanceReceipts))
                Toggle("Extract .zip archives automatically", isOn: binding(\.autoExtractArchives))
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

            Section {
                Toggle("Throttle on a schedule", isOn: scheduleEnabledBinding)
                if model.settings.bandwidthSchedule?.isEnabled == true {
                    DatePicker("From", selection: scheduleStartBinding, displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: scheduleEndBinding, displayedComponents: .hourAndMinute)
                    Toggle("Unlimited during this window", isOn: scheduleUnlimitedBinding)
                    if model.settings.bandwidthSchedule?.limitBytesPerSecond != nil {
                        HStack {
                            Text("Limit")
                            Spacer()
                            TextField("1", value: scheduleLimitMBs, format: .number)
                                .labelsHidden()
                                .frame(width: 70)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .accessibilityLabel("Scheduled limit")
                            Text("MB/s").foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Bandwidth Schedule")
            } footer: {
                Text("""
                Overrides the speed limit above during this window — throttle during work hours, \
                or go unlimited overnight. A window whose end is before its start wraps past midnight.
                """)
            }

            Section {
                Toggle("Watch clipboard for links", isOn: Binding(
                    get: { model.clipboardMonitoringEnabled },
                    set: { model.clipboardMonitoringEnabled = $0 }
                ))
                Toggle("Ask which quality to download", isOn: Binding(
                    get: { model.askQualityEnabled },
                    set: { model.askQualityEnabled = $0 }
                ))
                Toggle("Download subtitles when available", isOn: Binding(
                    get: { model.grabSubtitlesEnabled },
                    set: { model.grabSubtitlesEnabled = $0 }
                ))
            } header: {
                Text("Media & Capture")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("""
                    Applies wherever CloakDrop grabs a video — a link you paste, the built-in browser, \
                    or a share. Off grabs the best quality automatically — one click. On shows a picker \
                    for videos that offer several resolutions.
                    """)
                    Text("Subtitles are saved as a matching “.srt” file next to the video.")
                }
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

            Section {
                Picker("After all downloads finish", selection: postActionBinding) {
                    ForEach(SchedulerPostAction.allCases) { Text($0.localizedLabel).tag($0) }
                }
                if model.settings.resolvedPostAction.needsShortcutName {
                    TextField("Shortcut name", text: shortcutNameBinding, prompt: Text("Exact name in Shortcuts"))
                        .textFieldStyle(.roundedBorder)
                }
            } header: {
                Text("When Finished")
            } footer: {
                if model.settings.resolvedPostAction == .runShortcut {
                    Text("""
                    Runs a Shortcut of this name from your Shortcuts library — use it to sleep the \
                    Mac, tidy a folder, or anything else.
                    """)
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
                Text("""
                Controls how HTTP downloads and speed tests connect. A manual proxy also applies \
                to the built-in browser. FTP and FTPS connect directly.
                """)
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

    // MARK: About

    private var about: some View {
        Form {
            // The hero header (icon, name, version, credit). Tap the icon five times for a Matrix
            // easter egg (see AboutHeaderView). Zero row insets so the rain fills the card edge-to-edge.
            Section {
                AboutHeaderView(version: Self.appVersion)
                    .listRowInsets(EdgeInsets())
            }

            Section {
                linkRow(symbol: "person.crop.circle", label: Text(verbatim: "github.com/sumitsahoo"), url: AppLinks.author)
                linkRow(
                    symbol: "chevron.left.forwardslash.chevron.right",
                    label: Text(verbatim: "github.com/cloakyard/cloakdrop"),
                    url: AppLinks.repository
                )
                linkRow(symbol: "ladybug", label: Text("Report a Bug"), url: BugReport.issueURL)
            }
        }
        .formStyle(.grouped)
        .scrollBounceBehavior(.basedOnSize)
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

    private var shortcutNameBinding: Binding<String> {
        Binding(
            get: { model.settings.postCompletionShortcutName ?? "" },
            set: { newValue in
                var settings = model.settings
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.postCompletionShortcutName = trimmed.isEmpty ? nil : newValue
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

    // MARK: Bandwidth schedule bindings

    /// Mutate the schedule, materializing a sensible default the first time it's enabled.
    private func updateSchedule(_ transform: (inout BandwidthSchedule) -> Void) {
        var settings = model.settings
        var schedule = settings.bandwidthSchedule ?? BandwidthSchedule(isEnabled: true)
        transform(&schedule)
        settings.bandwidthSchedule = schedule
        model.updateSettings(settings)
    }

    private var scheduleEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.settings.bandwidthSchedule?.isEnabled ?? false },
            set: { on in updateSchedule { $0.isEnabled = on } }
        )
    }

    /// A start/end minute-of-day rendered as a `Date` today, for the hour-and-minute `DatePicker`.
    private func minuteBinding(_ keyPath: WritableKeyPath<BandwidthSchedule, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minute = model.settings.bandwidthSchedule?[keyPath: keyPath] ?? 0
                return Calendar.current.startOfDay(for: Date())
                    .addingTimeInterval(TimeInterval(minute * 60))
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                updateSchedule { $0[keyPath: keyPath] = minute }
            }
        )
    }

    private var scheduleStartBinding: Binding<Date> { minuteBinding(\.startMinute) }
    private var scheduleEndBinding: Binding<Date> { minuteBinding(\.endMinute) }

    private var scheduleUnlimitedBinding: Binding<Bool> {
        Binding(
            get: { model.settings.bandwidthSchedule?.limitBytesPerSecond == nil },
            set: { unlimited in updateSchedule { $0.limitBytesPerSecond = unlimited ? nil : 1_000_000 } }
        )
    }

    private var scheduleLimitMBs: Binding<Double> {
        Binding(
            get: { Double(model.settings.bandwidthSchedule?.limitBytesPerSecond ?? 0) / 1_000_000 },
            set: { mb in updateSchedule { $0.limitBytesPerSecond = Int64(max(0.1, mb) * 1_000_000) } }
        )
    }
}
