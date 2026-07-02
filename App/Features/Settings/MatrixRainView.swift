import SwiftUI

/// The About-page app icon with a hidden toggle: tap the tile more than five times and it fills
/// with Matrix "digital rain" (masked to the icon's silhouette). Tap the rain to switch it back
/// off and re-arm the counter, so the gag is replayable. Purely decorative — no user-facing text,
/// so nothing here is localized.
struct AboutIconView: View {
    @State private var taps = 0
    @State private var matrixMode = false

    var body: some View {
        ZStack {
            icon.opacity(matrixMode ? 0 : 1)

            // Only mount the Canvas while the egg is active: `TimelineView(.animation)` redraws every
            // display frame as long as it's in the tree, so a permanently-present-but-hidden rain would
            // burn CPU/GPU the whole time the About pane is open. Gating it keeps it idle when off.
            if matrixMode {
                MatrixRainView()
                    .mask { icon }
                    .shadow(color: .green.opacity(0.55), radius: 10)
                    .transition(.opacity)
            }
        }
        .frame(width: 96, height: 96)
        .scaleEffect(matrixMode ? 1.04 : 1)
        .contentShape(.rect)
        .onTapGesture { registerTap() }
        .animation(.easeInOut(duration: 0.45), value: matrixMode)
        // Brand name is verbatim elsewhere too, so keep it out of the String Catalog.
        .accessibilityLabel(Text(verbatim: "CloakDrop"))
    }

    // A pre-glassed copy of the app icon (baked by scripts/bake_about_icon.swift from how macOS
    // composites it for the Dock), not `NSApp.applicationIconImage` — which lags a rebuilt icon via
    // the OS icon cache. SwiftUI's `Image` won't apply Tahoe's Liquid Glass to the flat AppIcon, so
    // the glass is baked into this asset to match how the icon actually looks in the Dock.
    private var icon: some View {
        Image("AboutAppIcon").resizable().interpolation(.high)
    }

    private func registerTap() {
        if matrixMode {            // tapping the rain dismisses it and re-arms the counter
            matrixMode = false
            taps = 0
            return
        }
        taps += 1
        if taps > 5 { matrixMode = true }   // "more than five times"
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
