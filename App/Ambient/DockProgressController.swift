import AppKit

/// Renders aggregate download progress onto the Dock icon as a high-contrast circular ring
/// with a centered percentage — so a user can glance at the Dock and read overall progress
/// without bringing the app forward.
@MainActor
final class DockProgressController {
    private let tileView = DockTileView()

    /// Last drawn (whole percent, badge count) — ambient refreshes that change nothing visible skip the redraw.
    private var lastDrawn: (percent: Int, activeCount: Int)?

    func update(fraction: Double?, activeCount: Int) {
        let tile = NSApp.dockTile

        guard let fraction else {
            lastDrawn = nil   // clearing is never gated; the next draw always goes through
            tile.badgeLabel = activeCount > 0 ? "\(activeCount)" : nil
            tile.contentView = nil   // revert to the plain app icon
            tile.display()
            return
        }

        let state = (percent: Int(min(1, max(0, fraction)) * 100), activeCount: activeCount)
        if let lastDrawn, lastDrawn == state { return }
        lastDrawn = state

        tile.badgeLabel = activeCount > 0 ? "\(activeCount)" : nil
        tileView.fraction = fraction
        tile.contentView = tileView
        tile.display()
    }
}

/// Custom Dock tile content: the app icon under a dark circular HUD with a bright white
/// progress ring and percentage. White-on-dark is used deliberately so the *filled* portion
/// of the ring stays legible regardless of the (indigo) app icon or the user's accent color.
private final class DockTileView: NSView {
    var fraction: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        guard let icon = NSApp.applicationIconImage else { return }
        icon.draw(in: bounds)

        // A macOS app icon's artwork fills only ~80% of its tile (the rest is transparent
        // padding for the shadow), so size the overlay against the *visible* icon — not the
        // full tile — to keep the ring inside the icon's squircle.
        let iconSide = min(bounds.width, bounds.height) * 0.80
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let clamped = CGFloat(min(1, max(0, fraction)))

        // Dark HUD disc just inside the icon art — a consistent canvas so the white ring and
        // label pop on any icon.
        let discRadius = iconSide * 0.46
        let discRect = NSRect(
            x: center.x - discRadius, y: center.y - discRadius,
            width: discRadius * 2, height: discRadius * 2
        )
        NSColor.black.withAlphaComponent(0.66).setFill()
        NSBezierPath(ovalIn: discRect).fill()

        // Ring geometry, sized within the disc.
        let ringDiameter = iconSide * 0.60
        let lineWidth = iconSide * 0.11
        let ringRect = NSRect(
            x: center.x - ringDiameter / 2, y: center.y - ringDiameter / 2,
            width: ringDiameter, height: ringDiameter
        )

        // Track: faint full circle so the ring is visible even at low percentages.
        let track = NSBezierPath(ovalIn: ringRect)
        track.lineWidth = lineWidth
        NSColor.white.withAlphaComponent(0.28).setStroke()
        track.stroke()

        // Progress arc: solid white, clockwise from 12 o'clock — the high-contrast "done" portion.
        if clamped > 0 {
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: center, radius: ringDiameter / 2,
                startAngle: 90, endAngle: 90 - clamped * 360,
                clockwise: true
            )
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            NSColor.white.setStroke()
            arc.stroke()
        }

        // Centered percentage.
        let percent = Int((clamped * 100).rounded())
        let text = "\(percent)%" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: iconSide * 0.20, weight: .heavy),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2),
            withAttributes: attributes
        )
    }
}
