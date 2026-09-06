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
    /// The moving highlight's peak color (alpha baked in). White reads on a colored fill; when the
    /// fill itself is white — the emphasized selected row — a white sweep would vanish, so callers
    /// pass a translucent dark tint there instead.
    var sweep: Color = .white.opacity(0.35)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let fillWidth = max(0, geo.size.width * min(1, max(0, fraction)))
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(tint)
                    .overlay {
                        if isActive && !reduceMotion {
                            ActivitySweep(peak: sweep)
                        }
                    }
                    .clipShape(Capsule())
                    .frame(width: fillWidth)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue(Format.percent(min(1, max(0, fraction))))
        // Ease between the engine's ~10 Hz progress ticks so the fill glides instead of stepping.
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: fraction)
    }
}

/// The soft highlight band that drifts along an active bar's fill. Driven by `TimelineView` so the
/// offset is a pure function of time — reliable where an `onAppear`-triggered `repeatForever`
/// implicit animation can silently fail to start.
private struct ActivitySweep: View {
    let peak: Color

    /// Seconds for one traversal, plus a short pause between passes.
    private let travelDuration = 1.3
    private let pause = 0.5

    var body: some View {
        GeometryReader { geo in
            let band = max(34, geo.size.width * 0.4)
            let span = geo.size.width + band                // fully off-screen at both ends
            let period = travelDuration + pause
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
                // Advance only during the travel window; rest off-screen-left during the pause.
                let progress = min(1, max(0, t / travelDuration))
                LinearGradient(
                    colors: [peak.opacity(0), peak, peak.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: band)
                .offset(x: -band + progress * span)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
