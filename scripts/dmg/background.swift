// Renders the CloakDrop installer DMG background — the elegant drag-to-Applications art.
//
// Source of truth for the DMG artwork; edit this to iterate. `make-dmg.sh` runs it and tags the
// output 144 dpi so it stays crisp on Retina. The layout is authored in 720x640 points and drawn
// through a flipped handler (top-left origin, y increases downward). Rasterizes at 2x.
//
//   swift background.swift <app-icon.png> <out.png>
//
// SF Rounded wordmark, soft framed cards behind each icon row, dimensional brand-purple step
// badges, and a single-polygon arrow — on a soft lavender gradient.

import AppKit

let W: CGFloat = 720
let H: CGFloat = 640

let iconPath = CommandLine.arguments[1]   // pre-glassed app icon PNG for the header
let outPath  = CommandLine.arguments[2]

let brand      = NSColor(srgbRed: 0.357, green: 0.357, blue: 0.871, alpha: 1)
let brandDeep  = NSColor(srgbRed: 0.286, green: 0.286, blue: 0.780, alpha: 1)
let ink        = NSColor(srgbRed: 0.13,  green: 0.12,  blue: 0.17,  alpha: 1)
let secondary  = NSColor(srgbRed: 0.40,  green: 0.40,  blue: 0.47,  alpha: 1)
let gradTop    = NSColor(srgbRed: 0.909, green: 0.906, blue: 0.980, alpha: 1)
let gradBottom = NSColor(srgbRed: 0.965, green: 0.965, blue: 0.992, alpha: 1)
let panelShade = NSColor(srgbRed: 0.25,  green: 0.24,  blue: 0.45,  alpha: 0.14)

func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let d = base.fontDescriptor.withDesign(.rounded) { return NSFont(descriptor: d, size: size) ?? base }
    return base
}

func draw(_ s: String, _ font: NSFont, _ color: NSColor, centerX: CGFloat, centerY: CGFloat) {
    let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    let sz = str.size()
    str.draw(at: NSPoint(x: centerX - sz.width / 2, y: centerY - sz.height / 2))
}

/// A soft translucent card that frames an icon row so the Finder icons read as sitting in a well.
func drawCard(_ rect: NSRect) {
    let ctx = NSGraphicsContext.current!
    ctx.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = panelShade
    shadow.shadowBlurRadius = 26
    shadow.shadowOffset = NSSize(width: 0, height: -7)
    shadow.set()
    let path = NSBezierPath(roundedRect: rect, xRadius: 26, yRadius: 26)
    NSColor.white.withAlphaComponent(0.72).setFill()
    path.fill()
    ctx.restoreGraphicsState()
    // Faint top-down sheen for depth.
    ctx.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.45), NSColor.white.withAlphaComponent(0)])!
        .draw(in: rect, angle: -90)
    ctx.restoreGraphicsState()
    // Hairline highlight border.
    NSColor.white.withAlphaComponent(0.85).setStroke()
    let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 26, yRadius: 26)
    border.lineWidth = 1
    border.stroke()
}

/// A numbered brand badge (with sheen + soft shadow) followed by instruction text, left-aligned to
/// the card edge so the layout doesn't read as rigidly centered.
let stepLeftX: CGFloat = 96
func drawStep(_ number: String, _ text: String, centerY: CGFloat) {
    let ctx = NSGraphicsContext.current!
    let badgeD: CGFloat = 26
    let gap: CGFloat = 12
    let font = roundedFont(16, .medium)
    let textStr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink])
    let tsz = textStr.size()
    let startX = stepLeftX
    let badge = NSRect(x: startX, y: centerY - badgeD / 2, width: badgeD, height: badgeD)
    let badgePath = NSBezierPath(ovalIn: badge)

    ctx.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = brand.withAlphaComponent(0.4)
    shadow.shadowBlurRadius = 7
    shadow.shadowOffset = NSSize(width: 0, height: -2)
    shadow.set()
    brandDeep.setFill()
    badgePath.fill()
    ctx.restoreGraphicsState()
    ctx.saveGraphicsState()
    badgePath.addClip()
    NSGradient(colors: [brand, brandDeep])!.draw(in: badge, angle: -90)
    ctx.restoreGraphicsState()

    let numStr = NSAttributedString(string: number,
        attributes: [.font: roundedFont(14.5, .bold), .foregroundColor: NSColor.white])
    let nsz = numStr.size()
    numStr.draw(at: NSPoint(x: badge.midX - nsz.width / 2, y: badge.midY - nsz.height / 2))
    textStr.draw(at: NSPoint(x: startX + badgeD + gap, y: centerY - tsz.height / 2))
}

/// One connected polygon — shaft + head as a single filled path, so there's no seam where they
/// meet. Points right, from x0 to the tip. Filled with a brand gradient and a soft shadow.
func drawArrow(x0: CGFloat, tipX: CGFloat, y: CGFloat) {
    let shaftH: CGFloat = 8
    let headH: CGFloat = 32
    let headLen: CGFloat = 27
    let xh = tipX - headLen
    let p = NSBezierPath()
    p.move(to: NSPoint(x: x0, y: y - shaftH / 2))
    p.line(to: NSPoint(x: xh, y: y - shaftH / 2))
    p.line(to: NSPoint(x: xh, y: y - headH / 2))
    p.line(to: NSPoint(x: tipX, y: y))
    p.line(to: NSPoint(x: xh, y: y + headH / 2))
    p.line(to: NSPoint(x: xh, y: y + shaftH / 2))
    p.line(to: NSPoint(x: x0, y: y + shaftH / 2))
    p.close()

    let ctx = NSGraphicsContext.current!
    ctx.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = brand.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 8
    shadow.shadowOffset = NSSize(width: 0, height: -2)
    shadow.set()
    brandDeep.setFill()
    p.fill()
    ctx.restoreGraphicsState()
    ctx.saveGraphicsState()
    p.addClip()
    NSGradient(colors: [brand, brandDeep])!.draw(in: p.bounds, angle: 0)
    ctx.restoreGraphicsState()
}

let image = NSImage(size: NSSize(width: W, height: H), flipped: true) { _ in
    // Background gradient (top-left origin: top is y=0).
    NSGradient(colors: [gradTop, gradBottom])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    // Soft brand glow behind the header for depth.
    if let glow = NSGradient(colors: [brand.withAlphaComponent(0.16), brand.withAlphaComponent(0)]) {
        glow.draw(fromCenter: NSPoint(x: W / 2, y: 72), radius: 0,
                  toCenter: NSPoint(x: W / 2, y: 72), radius: 280, options: [])
    }

    // Framed wells behind the two icon rows (Finder overlays the real icons on top).
    drawCard(NSRect(x: 96, y: 232, width: 528, height: 156))    // install row
    drawCard(NSRect(x: 96, y: 448, width: 528, height: 150))    // extension row

    // Header: logo, wordmark, tagline.
    if let logo = NSImage(contentsOfFile: iconPath) {
        let box = NSRect(x: W / 2 - 31, y: 26, width: 62, height: 62)
        let shadow = NSShadow()
        shadow.shadowColor = brand.withAlphaComponent(0.38)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        NSGraphicsContext.current?.saveGraphicsState()
        shadow.set()
        logo.draw(in: box)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
    draw("CloakDrop", roundedFont(32, .bold), ink, centerX: W / 2, centerY: 114)
    draw("Private download manager for macOS", roundedFont(13.5, .regular), secondary, centerX: W / 2, centerY: 140)

    // Step 1 — install. The arrow bridges the app icon and Applications alias placed by Finder.
    drawStep("1", "Drag CloakDrop into your Applications folder", centerY: 198)
    drawArrow(x0: 287, tipX: 433, y: 300)

    // Step 2 — extension. Finder overlays "Chrome Extension" and "Read Me.txt" in the lower card.
    drawStep("2", "Optional — load the Chrome Extension (see Read Me)", centerY: 424)

    return true
}

// Rasterize to a 2x bitmap; make-dmg.sh tags it 144 dpi so Finder renders it crisp at 720x640 pt.
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * 2), pixelsHigh: Int(H * 2),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: W, height: H))
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png encode failed") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) at \(Int(W * 2))x\(Int(H * 2)) px")
