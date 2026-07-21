import AppKit
import SwiftUI

/// The app-wide design tokens: one card fill and a two-step corner-radius scale, so sibling
/// surfaces (inspector cards, settings cards, shelf rows, banners) read as one system instead of
/// each picking its own values.
enum Design {
    /// Standalone cards and tiles (inspector sections, speed tiles, banners, callouts).
    static let cardRadius: CGFloat = 12
    /// Small inline elements (thumbnails, text editors, compact badges).
    static let inlineRadius: CGFloat = 6
    /// The one fill behind every inset card. `quaternarySystemFill` stays visible in dark mode,
    /// unlike `.quaternary` dimmed with an extra opacity multiplier, which fades toward invisible.
    static let cardFill = Color(nsColor: .quaternarySystemFill)
}

/// Whether list selection is currently drawn *emphasized* (the accent-colored highlight): the list
/// has keyboard focus in an active window. Rows read this to decide between white-on-accent and
/// normal tinted content. Provided by the list container — SwiftUI's own `backgroundProminence`
/// is not reliably raised for `.inset` lists on macOS, so we derive it from focus + window state.
private struct SelectionEmphasisKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var selectionEmphasis: Bool {
        get { self[SelectionEmphasisKey.self] }
        set { self[SelectionEmphasisKey.self] = newValue }
    }
}

/// The app's one progress bar: a thin capsule with an explicit fill color, shared by the list rows
/// and the inspector so progress reads identically everywhere. Drawn by hand rather than with a
/// linear `ProgressView`, whose platform rendering can fall back to the window accent color and
/// lose the status tint (and whose intrinsic height varies).
struct CapsuleProgressBar: View {
    let fraction: Double
    var tint: Color = .accentColor
    var track: AnyShapeStyle = AnyShapeStyle(.quaternary)
    var height: CGFloat = 4
    /// While true (an active transfer), a faint highlight sweeps along the fill so the bar reads
    /// as *working*, not stalled — even between progress ticks. Off for paused/static bars, and
    /// suppressed entirely under Reduce Motion.
    var isActive = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let fillWidth = max(0, geo.size.width * min(1, max(0, fraction)))
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(tint)
                    .overlay {
                        if isActive && !reduceMotion {
                            ActivitySweep()
                        }
                    }
                    .clipShape(Capsule())
                    .frame(width: fillWidth)
            }
        }
        .frame(height: height)
        // Ease between the engine's ~10 Hz progress ticks so the fill glides instead of stepping.
        .animation(.smooth(duration: 0.3), value: fraction)
    }
}

/// The soft highlight band that drifts along an active bar's fill. Core Animation drives the
/// repeat, so it costs no per-frame SwiftUI work.
private struct ActivitySweep: View {
    @State private var sweeping = false

    var body: some View {
        GeometryReader { geo in
            let band = max(28, geo.size.width * 0.3)
            LinearGradient(
                colors: [.white.opacity(0), .white.opacity(0.3), .white.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: band)
            .offset(x: sweeping ? geo.size.width : -band)
            .animation(.linear(duration: 1.8).delay(0.6).repeatForever(autoreverses: false), value: sweeping)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { sweeping = true }
    }
}
