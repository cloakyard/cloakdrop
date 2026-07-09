// Renders the CloakDrop installer DMG background — the elegant drag-to-Applications art.
//
// Source of truth for the DMG artwork; edit this to iterate. `make-dmg.sh` runs it and tags the
// output 144 dpi so it stays crisp on Retina. The layout is authored in 720x584 points and drawn
// through a flipped handler (top-left origin, y increases downward). Rasterizes at 2x.
//
//   swift background.swift <app-icon.png> <out.png>
//
// Layout is deliberately *off-centre*: a left-aligned brand lockup (icon + SF Rounded wordmark +
// tagline) sits in a soft brand wash across the top, then the centred drag-to-install card with a
// single-polygon swoosh arrow filled with the same periwinkle→indigo gradient as the app icon.

import AppKit

let W: CGFloat = 720
let H: CGFloat = 584

let iconPath = CommandLine.arguments[1]   // pre-glassed app icon PNG for the header
let outPath  = CommandLine.arguments[2]

let brand      = NSColor(srgbRed: 0.357, green: 0.357, blue: 0.871, alpha: 1)
let ink        = NSColor(srgbRed: 0.13,  green: 0.12,  blue: 0.17,  alpha: 1)
let secondary  = NSColor(srgbRed: 0.40,  green: 0.40,  blue: 0.47,  alpha: 1)
let gradTop    = NSColor(srgbRed: 0.909, green: 0.906, blue: 0.980, alpha: 1)
let gradBottom = NSColor(srgbRed: 0.965, green: 0.965, blue: 0.992, alpha: 1)
let panelShade = NSColor(srgbRed: 0.25,  green: 0.24,  blue: 0.45,  alpha: 0.14)
// Arrow gradient — the app icon's own periwinkle→indigo, from a light tail to a deep head, so the
// arrow reads as the same material as the icon (not the flat solid it was before).
let arrowLight = NSColor(srgbRed: 0.545, green: 0.533, blue: 0.914, alpha: 1)   // #8B88E9 icon periwinkle
let arrowDeep  = NSColor(srgbRed: 0.278, green: 0.243, blue: 0.741, alpha: 1)   // #473EBD deep indigo

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

/// Left-aligned text, vertically centred on `centerY` — for the editorial header lockup.
func drawLeft(_ s: String, _ font: NSFont, _ color: NSColor, x: CGFloat, centerY: CGFloat) {
    let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    let sz = str.size()
    str.draw(at: NSPoint(x: x, y: centerY - sz.height / 2))
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

/// A soft-tipped instruction line, centred above the card.
func drawInstruction(_ text: String, centerY: CGFloat) {
    draw(text, roundedFont(17, .semibold), ink, centerX: W / 2, centerY: centerY)
}

/// A curved "swoosh" arrow from the app icon to the Applications alias — a gentle downward bow with
/// a tangent-aligned head, so it feels hand-drawn rather than stamped. Stroke + head are filled with
/// the app icon's periwinkle→indigo gradient (soft shadow underneath), so there's no seam.
func drawCurvedArrow(x0: CGFloat, tipX: CGFloat, y: CGFloat) {
    let dip: CGFloat = 15          // how far the middle bows below the icon centre line
    let lineW: CGFloat = 9
    let headLen: CGFloat = 30
    let headH: CGFloat = 33
    let dx = tipX - x0

    // Cubic bow: dips in the first half, flattens as it approaches the head so the tip barely tilts.
    // The shaft runs almost all the way to the tip; the head then sits *over* its end (see overlap).
    let pEnd = CGPoint(x: tipX - 8, y: y + dip * 0.10)
    let p0 = CGPoint(x: x0, y: y)
    let p1 = CGPoint(x: x0 + dx * 0.30, y: y + dip)
    let p2 = CGPoint(x: pEnd.x - dx * 0.12, y: y + dip * 0.42)
    let shaft = CGMutablePath()
    shaft.move(to: p0)
    shaft.addCurve(to: pEnd, control1: p1, control2: p2)
    let stroked = shaft.copy(strokingWithWidth: lineW, lineCap: .round, lineJoin: .round, miterLimit: 10)

    // Arrowhead oriented along the shaft's end tangent. Its base sits `overlap` px *behind* the shaft
    // end, so the triangle swallows the shaft's rounded cap — the two fills merge with no seam.
    let tan = CGVector(dx: pEnd.x - p2.x, dy: pEnd.y - p2.y)
    let mag = max(hypot(tan.dx, tan.dy), 0.001)
    let ux = tan.dx / mag, uy = tan.dy / mag           // unit along the arrow
    let nx = -uy, ny = ux                              // unit normal
    let overlap: CGFloat = 14
    let baseC = CGPoint(x: pEnd.x - ux * overlap, y: pEnd.y - uy * overlap)
    let tip = CGPoint(x: baseC.x + ux * headLen, y: baseC.y + uy * headLen)
    let baseL = CGPoint(x: baseC.x + nx * headH / 2, y: baseC.y + ny * headH / 2)
    let baseR = CGPoint(x: baseC.x - nx * headH / 2, y: baseC.y - ny * headH / 2)
    // Rounded triangle: each corner is a tangent arc, so the tip and wings are soft, not sharp.
    let corner: CGFloat = 5.5
    let head = CGMutablePath()
    head.move(to: CGPoint(x: (baseR.x + tip.x) / 2, y: (baseR.y + tip.y) / 2))   // start mid-edge, off any corner
    head.addArc(tangent1End: tip, tangent2End: baseL, radius: corner)
    head.addArc(tangent1End: baseL, tangent2End: baseR, radius: corner)
    head.addArc(tangent1End: baseR, tangent2End: tip, radius: corner)
    head.closeSubpath()

    // Fill the shaft and head as two independent, overlapping pieces — NOT one combined path.
    // (Their stroke outlines wind oppositely, so a single nonzero/even-odd fill would punch a hole
    // at the overlap.) Overlapping solid fills merge cleanly into one continuous arrow.
    let shaftPath = NSBezierPath(cgPath: stroked)
    let headPath = NSBezierPath(cgPath: head)
    let bounds = stroked.boundingBoxOfPath.union(head.boundingBoxOfPath)

    let ctx = NSGraphicsContext.current!
    ctx.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = arrowDeep.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = 9
    shadow.shadowOffset = NSSize(width: 0, height: -2)
    shadow.set()
    arrowDeep.setFill()   // solid base beneath the gradient so no anti-aliased seam shows through
    shaftPath.fill()
    headPath.fill()
    ctx.restoreGraphicsState()
    // Icon gradient, clipped to each piece over their shared bounds so it reads as one shape. Angle
    // tilts slightly down-right so the tail is light and the head is deepest (matches the icon flow).
    for piece in [shaftPath, headPath] {
        ctx.saveGraphicsState()
        piece.addClip()
        NSGradient(colors: [arrowLight, arrowDeep])!.draw(in: bounds, angle: -14)
        ctx.restoreGraphicsState()
    }
}

let image = NSImage(size: NSSize(width: W, height: H), flipped: true) { _ in
    // Background gradient (top-left origin: top is y=0).
    NSGradient(colors: [gradTop, gradBottom])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    // Gentle brand wash across the top so the left-aligned header reads as an intentional band and
    // the upper negative space is filled — no hard divider needed.
    if let wash = NSGradient(colors: [brand.withAlphaComponent(0.13), brand.withAlphaComponent(0)]) {
        wash.draw(in: NSRect(x: 0, y: 0, width: W, height: 156), angle: -90)
    }

    // Header: left-aligned brand lockup (icon + wordmark + tagline), anchored to the left margin so
    // the composition isn't a single rigid centre stack.
    let iconSize: CGFloat = 60
    let iconX: CGFloat = 64
    let iconY: CGFloat = 46
    if let logo = NSImage(contentsOfFile: iconPath) {
        let box = NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize)
        let shadow = NSShadow()
        shadow.shadowColor = brand.withAlphaComponent(0.36)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        NSGraphicsContext.current?.saveGraphicsState()
        shadow.set()
        logo.draw(in: box)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
    let textX = iconX + iconSize + 18
    drawLeft("CloakDrop", roundedFont(30, .bold), ink, x: textX, centerY: iconY + 21)
    drawLeft("Private download manager for macOS", roundedFont(13.5, .regular), secondary, x: textX + 1, centerY: iconY + 45)

    // Framed well behind the drag-to-install icon row (Finder overlays the real icons on top).
    drawCard(NSRect(x: 84, y: 232, width: 552, height: 172))    // install row

    // One clean instruction, then the curved arrow bridging the app icon and the Applications alias
    // (Finder places both at y=310 inside the card).
    drawInstruction("Drag CloakDrop to your Applications folder", centerY: 202)
    drawCurvedArrow(x0: 292, tipX: 430, y: 310)

    // "Read Me.txt" (placed by Finder at y=488) sits on its own below the card — its label speaks
    // for itself, so nothing overlaps it.

    return true
}

// Rasterize to a 2x bitmap; make-dmg.sh tags it 144 dpi so Finder renders it crisp at 720x584 pt.
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
