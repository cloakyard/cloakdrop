import SwiftUI
import DownloadModels

/// Settings ▸ Speed Test: a manual, user-initiated connection test. Nothing runs until the
/// user presses Start — keeping "no connections you didn't choose" true by default.
/// The run itself lives on `AppModel.speedTest`, so this view is purely presentation.
struct SpeedTestSettingsView: View {
    @Environment(AppModel.self) private var model

    private var runner: SpeedTestRunner { model.speedTest }

    var body: some View {
        Form {
            Section {
                Picker("Test with", selection: providerBinding) {
                    ForEach(SpeedTestProvider.allCases) { Text($0.localizedLabel).tag($0) }
                }
                .disabled(runner.isRunning)
            } header: {
                Text("Server")
            } footer: {
                Text("""
                Runs only when you start it. A test exchanges data with the provider chosen \
                above — CloakDrop never contacts a test server on its own.
                """)
            }

            Section {
                HStack(spacing: 40) {
                    SpeedometerView(
                        title: String(localized: "Download speed"),
                        bytesPerSecond: displayedDownloadRate,
                        isActive: runner.status == .running(.download)
                    )
                    SpeedometerView(
                        title: String(localized: "Upload speed"),
                        bytesPerSecond: displayedUploadRate,
                        isActive: runner.status == .running(.upload)
                    )
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                LabeledContent("Latency") {
                    Text(latencyText).monospacedDigit()
                }
                if let jitter = jitterText {
                    LabeledContent("Jitter") {
                        Text(jitter).monospacedDigit()
                    }
                }
                if let loaded = loadedLatencyText {
                    LabeledContent("Latency under load") {
                        Text(loaded).monospacedDigit()
                    }
                }
            } header: {
                Text("Results")
            } footer: {
                statusFooter
            }

            Section {
                HStack {
                    Spacer()
                    Button {
                        if runner.isRunning {
                            runner.stop()
                        } else {
                            runner.start(
                                provider: model.settings.resolvedSpeedTestProvider,
                                proxy: model.settings.resolvedProxy
                            )
                        }
                    } label: {
                        Text(runner.isRunning ? "Stop Test" : "Start Test")
                            .frame(minWidth: 110)
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .scrollBounceBehavior(.basedOnSize)
        // The test is a deliberate, watched action; leaving the pane abandons it.
        .onDisappear { runner.stop() }
    }

    // MARK: Displayed values

    /// Live numbers while a test runs; the stored result (if any) otherwise.
    private var displayedDownloadRate: Double? {
        if runner.isRunning { return runner.liveDownloadRate }
        return runner.lastResult?.downloadBytesPerSecond
    }

    private var displayedUploadRate: Double? {
        if runner.isRunning { return runner.liveUploadRate }
        return runner.lastResult?.uploadBytesPerSecond
    }

    private var latencyText: String {
        if runner.isRunning { return runner.liveLatency.map(Self.milliseconds) ?? "—" }
        return runner.lastResult.map { Self.milliseconds($0.idleLatencyMilliseconds) } ?? "—"
    }

    private var jitterText: String? {
        guard !runner.isRunning, let result = runner.lastResult else { return nil }
        return Self.milliseconds(result.jitterMilliseconds)
    }

    private var loadedLatencyText: String? {
        guard !runner.isRunning, let loaded = runner.lastResult?.loadedLatencyMilliseconds else { return nil }
        return Self.milliseconds(loaded)
    }

    private static func milliseconds(_ value: Double) -> String {
        String(localized: "\(Int(value.rounded())) ms")
    }

    @ViewBuilder private var statusFooter: some View {
        switch runner.status {
        case .running(let phase):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(phase.localizedLabel)
                if let server = runner.serverName {
                    Text(verbatim: "· \(server)").foregroundStyle(.tertiary)
                }
            }
        case .failed:
            Text("The speed test could not finish. Check your connection and try again.")
                .foregroundStyle(.red)
        case .idle:
            if let result = runner.lastResult {
                Text("Last tested \(result.date.formatted(.relative(presentation: .named))) · \(result.serverName)")
            } else {
                Text("Measures your connection's real download, upload, and latency.")
            }
        }
    }

    // MARK: Bindings

    private var providerBinding: Binding<SpeedTestProvider> {
        Binding(
            get: { model.settings.resolvedSpeedTestProvider },
            set: { newValue in
                var settings = model.settings
                settings.speedTestProvider = newValue
                model.updateSettings(settings)
            }
        )
    }
}

/// A speedometer dial: a 270° arc with a needle on a logarithmic scale (0 → ~1 Gbit/s), so
/// both a struggling hotel Wi-Fi and a fiber line produce a readable sweep. The measured
/// value sits under the dial; the needle animates as live rates stream in.
private struct SpeedometerView: View {
    var title: String
    /// Current value, or `nil` when neither a live rate nor a stored result exists.
    var bytesPerSecond: Double?
    /// Whether this metric is the one being measured right now (tints the dial).
    var isActive: Bool

    /// Fraction of the dial's sweep. Log-scaled: 1 Mbit/s ≈ 10%, 100 Mbit/s ≈ 67%, 1 Gbit/s = 100%.
    private var fraction: Double {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return 0 }
        let megabits = bytesPerSecond * 8 / 1_000_000
        return min(1, log10(1 + megabits) / log10(1001.0))
    }

    /// Speed tests conventionally report megabits (what ISPs sell), not the megabytes the
    /// download list shows — matching Speedtest/Fast so users can compare results directly.
    private var valueText: String {
        guard let bytesPerSecond, bytesPerSecond >= 1 else { return "—" }
        let megabits = bytesPerSecond * 8 / 1_000_000
        let digits = megabits < 100 ? 1 : 0
        return String(localized: "\(megabits.formatted(.number.precision(.fractionLength(digits)))) Mbps")
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                dialArc(to: 1)
                    .stroke(.quaternary, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                dialArc(to: fraction)
                    .stroke(
                        isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.55)),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round)
                    )
                needle
            }
            .frame(width: 110, height: 100)
            .animation(.smooth(duration: 0.35), value: fraction)

            // The reading sits below the dial — inside the arc it crowds the needle and the
            // arc's rounded end caps.
            VStack(spacing: 2) {
                Text(valueText)
                    .font(.headline)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(valueText)
    }

    /// The dial sweep: 270° starting at the lower-left (trim is drawn from 3 o'clock, so
    /// rotating +135° puts the gap symmetrically at the bottom).
    private func dialArc(to sweepFraction: Double) -> some Shape {
        Circle()
            .trim(from: 0, to: 0.75 * sweepFraction)
            .rotation(.degrees(135))
    }

    private var needle: some View {
        Capsule()
            .fill(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(width: 3, height: 30)
            .offset(y: -15)
            // 0 → lower-left end of the arc (-135° from vertical), full → lower-right (+135°).
            .rotationEffect(.degrees(-135 + 270 * fraction))
    }
}
