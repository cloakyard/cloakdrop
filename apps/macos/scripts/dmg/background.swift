// Renders the CloakDrop installer DMG background.
//
// The artwork is authored in the Finder window's 760x570-point content area and rasterized at
// 2x. Finder overlays the real CloakDrop, Applications, and Install Guide icons, so this file
// only draws the open Air composition, instructions, horizon and directional cue.
//
//   swift background.swift <app-icon.png> <out.png>

import AppKit

let W: CGFloat = 760
let H: CGFloat = 570

let iconPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]

func hex(_ string: String, _ alpha: CGFloat = 1) -> NSColor {
    var valueString = string
    if valueString.hasPrefix("#") { valueString.removeFirst() }
    var value: UInt64 = 0
    Scanner(string: valueString).scanHexInt64(&value)
    return NSColor(
        srgbRed: CGFloat((value >> 16) & 0xff) / 255,
        green: CGFloat((value >> 8) & 0xff) / 255,
        blue: CGFloat(value & 0xff) / 255,
        alpha: alpha
    )
}

// Static Air artwork uses the canonical light palette in apps/site/src/styles/air.css.
// Finder supports one bitmap per installer; the app itself still follows system appearance.
let page = hex("#FAFBFC")
let ink = hex("#202329")
let secondary = hex("#525B68")
let muted = hex("#646B76")
let line = hex("#E1E5EB")
let accent = hex("#285AD7")

func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular,
          color: NSColor, x: CGFloat, y: CGFloat, centered: Bool = false,
          tracking: CGFloat = 0) {
    let label = NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .kern: tracking
    ])
    label.draw(at: NSPoint(x: centered ? x - label.size().width / 2 : x,
                          y: y - label.size().height / 2))
}

let image = NSImage(size: NSSize(width: W, height: H), flipped: true) { _ in
    let context = NSGraphicsContext.current!
    context.imageInterpolation = .high
    page.setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()

    // Keep the original mark, with the family's quiet single-colour wordmark.
    NSImage(contentsOfFile: iconPath)?.draw(in: NSRect(x: 40, y: 28, width: 36, height: 36))
    text("CloakDrop", size: 18, weight: .medium, color: ink, x: 86, y: 46, tracking: -0.5)
    text("Apple silicon · macOS 26+", size: 12, color: secondary,
         x: 552, y: 46)

    text("A little more care.", size: 34, color: ink,
         x: W / 2, y: 116, centered: true, tracking: -1.25)
    text("For every download.", size: 34, color: secondary,
         x: W / 2, y: 155, centered: true, tracking: -1.25)

    // Two soft offset planes echo the family horizon without competing with the real icons.
    for offset in [CGFloat(0), 11] {
        let horizon = NSBezierPath()
        horizon.move(to: NSPoint(x: 96, y: 207 + offset))
        horizon.curve(to: NSPoint(x: 664, y: 207 - offset / 2),
                      controlPoint1: NSPoint(x: 278, y: 194 + offset / 3),
                      controlPoint2: NSPoint(x: 472, y: 196 - offset / 2))
        context.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = accent.withAlphaComponent(0.14)
        glow.shadowBlurRadius = 6
        glow.shadowOffset = .zero
        glow.set()
        accent.withAlphaComponent(0.16).setStroke()
        horizon.lineWidth = 0.8
        horizon.stroke()
        context.restoreGraphicsState()
    }

    // Finder overlays the actual 96pt icons at (204, 282) and (556, 282).
    // Keep the path between them open: no fake controls, slots or simulated progress.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 350, y: 282))
    arrow.line(to: NSPoint(x: 410, y: 282))
    arrow.move(to: NSPoint(x: 401, y: 273))
    arrow.line(to: NSPoint(x: 410, y: 282))
    arrow.line(to: NSPoint(x: 401, y: 291))
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.lineWidth = 1.6
    secondary.setStroke()
    arrow.stroke()

    text("Drag CloakDrop to Applications.", size: 16, weight: .medium,
         color: ink, x: W / 2, y: 366, centered: true, tracking: -0.2)
    text("Then open it from Applications.", size: 13, color: secondary,
         x: W / 2, y: 390, centered: true)

    // The real Install Guide icon is centred at (380, 464), with Finder's own label.
    let divider = NSBezierPath()
    divider.move(to: NSPoint(x: 48, y: 418))
    divider.line(to: NSPoint(x: 276, y: 418))
    divider.move(to: NSPoint(x: 484, y: 418))
    divider.line(to: NSPoint(x: 712, y: 418))
    divider.lineWidth = 1
    line.setStroke()
    divider.stroke()
    text("Made with care.", size: 12, color: muted, x: 48, y: 542)
    text("drop.cloakyard.com", size: 12, color: muted, x: 604, y: 542)
    return true
}

// Finder displays the 1520x1140 bitmap at 760x570 points after make-dmg.sh tags it at 144 dpi.
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(W * 2),
    pixelsHigh: Int(H * 2),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .calibratedRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
bitmap.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
image.draw(in: NSRect(x: 0, y: 0, width: W, height: H))
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("png encode failed")
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) at \(Int(W * 2))x\(Int(H * 2)) px")
