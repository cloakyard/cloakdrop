import SwiftUI

/// The About page's hero header — the app icon, name, and version on a soft brand-purple card —
/// with a hidden, replayable easter egg. Tap the icon five times and the whole header fills with
/// Matrix "digital rain"; tap anywhere on it while it's raining to switch it off and re-arm the
/// counter. The gag is purely decorative; only the version line (whose key lives elsewhere) is
/// localized.
struct AboutHeaderView: View {
    /// Rendered app version, e.g. "1.0 (1)".
    let version: String

    @State private var taps = 0
    @State private var matrixMode = false

    /// Phosphor green used for the title/version while the rain is on.
    private static let phosphor = Color(red: 0.62, green: 1.0, blue: 0.62)

    // Rendered as a single grouped-Form row (see SettingsView.about), so the Section supplies the grey
    // card, width, and corner radius — identical to every other Settings tab. The Matrix easter egg
    // rides in as the row's background (which the Section clips to its rounded corners) only while
    // armed; the Canvas is otherwise absent, so no `TimelineView` redraws burn CPU when the egg is off.
    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .overlay {
                // While it rains, a transparent catcher turns any tap into "stop".
                if matrixMode { Color.clear.contentShape(.rect).onTapGesture { stop() } }
            }
            .listRowBackground(matrixMode ? AnyView(MatrixRainView()) : nil)
            .animation(.easeInOut(duration: 0.45), value: matrixMode)
    }

    private var content: some View {
        VStack(spacing: 12) {
            icon
                .frame(width: 84, height: 84)
                .scaleEffect(matrixMode ? 1.05 : 1)
                .shadow(color: .green.opacity(matrixMode ? 0.7 : 0), radius: 14)
                .contentShape(.rect)
                .onTapGesture { registerTap() }
                .accessibilityLabel(Text(verbatim: "CloakDrop"))
                .accessibilityAddTraits(.isButton)

            VStack(spacing: 3) {
                Text(verbatim: "CloakDrop")
                    .font(matrixMode
                          ? .title2.weight(.semibold).monospaced()
                          : .title2.weight(.semibold))
                    .foregroundStyle(matrixMode ? Self.phosphor : .primary)
                    .shadow(color: .green.opacity(matrixMode ? 0.8 : 0), radius: 8)
                Text("Version \(version)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(matrixMode ? Self.phosphor.opacity(0.85) : .secondary)
            }
        }
    }

    // A pre-glassed copy of the app icon (baked by scripts/bake_about_icon.swift from how macOS
    // composites it for the Dock), not `NSApp.applicationIconImage` — which lags a rebuilt icon via
    // the OS icon cache. SwiftUI's `Image` won't apply Tahoe's Liquid Glass to the flat AppIcon, so
    // the glass is baked into this asset to match how the icon actually looks in the Dock.
    private var icon: some View {
        Image("AboutAppIcon").resizable().interpolation(.high)
    }

    // MARK: Easter egg

    private func registerTap() {
        if matrixMode { stop(); return }        // tapping the icon while it rains dismisses it
        taps += 1
        if taps >= 5 { matrixMode = true }      // five taps arms the rain
    }

    private func stop() {                        // switch it off and re-arm the counter
        matrixMode = false
        taps = 0
    }
}

/// Matrix-style "digital rain": per-column trails of glyphs falling down a black field, each with a
/// near-white head and a fading green tail. Drawn in one `Canvas` with no per-frame stored state —
/// every column's motion and every cell's glyph are a pure function of elapsed time via a hash, so
/// there's nothing to keep in sync between frames. Reduce Motion renders a single still frame.
struct MatrixRainView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                Canvas { context, size in
                    Self.draw(in: &context, size: size, time: 1.2)
                }
            } else {
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        Self.draw(in: &context, size: size,
                                  time: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
            }
        }
        .background(.black)
    }

    // MARK: Rendering

    private static let fontSize: CGFloat = 11
    private static let cell: CGFloat = 12
    private static let tail = 14
    private static let font = Font.system(size: fontSize, weight: .semibold, design: .monospaced)

    /// Half-width katakana (the canonical Matrix glyphs) plus digits.
    private static let glyphs: [String] = {
        let katakana = (0xFF66...0xFF9D).compactMap { UnicodeScalar($0).map(String.init) }
        let digits = (0...9).map(String.init)
        return katakana + digits
    }()

    private static func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let cols = max(1, Int(size.width / cell))
        let rows = max(1, Int(size.height / cell) + 1)
        let gap = 6.0
        let cycle = Double(rows) + Double(tail) + gap   // rows the head travels before repeating

        for col in 0..<cols {
            let speed = 6.0 + hash01(col, 1) * 16.0                    // rows per second
            let offset = hash01(col, 2) * cycle                       // desync the columns
            let head = (time * speed + offset).truncatingRemainder(dividingBy: cycle)

            for tailIndex in 0..<tail {
                let row = Int(head) - tailIndex
                guard row >= 0, row < rows else { continue }          // enters top, exits bottom

                let flicker = Int((time + hash01(col, row)) * 9)      // glyph swaps ~9×/sec, staggered
                let pick = Int(hash01(col &* 13, row &* 7, flicker) * Double(glyphs.count))
                let glyph = glyphs[pick % glyphs.count]

                let point = CGPoint(x: CGFloat(col) * cell + cell / 2,
                                    y: CGFloat(row) * cell + cell / 2)
                context.draw(Text(glyph).font(font).foregroundStyle(color(tailIndex)),
                             at: point, anchor: .center)
            }
        }
    }

    /// Head is a near-white green; the tail fades to a dim, translucent green.
    private static func color(_ tailIndex: Int) -> Color {
        if tailIndex == 0 { return Color(red: 0.80, green: 1.0, blue: 0.80) }
        let fade = 1.0 - Double(tailIndex) / Double(tail)             // 1 at the head → 0 at the end
        return Color(red: 0.05, green: 0.35 + 0.55 * fade, blue: 0.15)
            .opacity(0.15 + 0.85 * fade)
    }

    /// Stable hash in `[0, 1)` from up to three integers (FNV-1a style) — the single source of
    /// pseudo-randomness, which is what lets the whole animation be a pure function of time.
    private static func hash01(_ a: Int, _ b: Int = 0, _ c: Int = 0) -> Double {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for value in [a, b, c] {
            h = (h ^ UInt64(bitPattern: Int64(value))) &* 0x0000_0100_0000_01b3
        }
        h ^= h >> 29
        return Double(h % 1_000_000) / 1_000_000.0
    }
}
