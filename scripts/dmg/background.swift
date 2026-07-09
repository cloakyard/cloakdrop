// Renders the CloakDrop installer DMG background — the elegant drag-to-Applications art.
//
// Source of truth for the DMG artwork; edit this to iterate. `make-dmg.sh` runs it and tags the
// output 144 dpi so it stays crisp on Retina. The layout is authored in 720x584 points and drawn
// through a flipped handler (top-left origin, y increases downward). Rasterizes at 2x.
//
//   swift background.swift <app-icon.png> <out.png>
//
// Off-centre by design: a left-aligned brand lockup (icon + SF Rounded wordmark + a two-line
// description) in a soft brand wash across the top, a GitHub link chip top-right, then the centred
// drag-to-install card with a tapered "smile" arrow (thin tail → thick head, an Amazon-style swoosh
// in our own periwinkle→indigo — the same gradient as the app icon).

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
// arrow reads as the same material as the icon.
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

/// A subtle centred "link chip" showing the GitHub URL — a soft brand pill, so it reads as a link
/// without shouting. (The DMG image isn't clickable; the real hyperlink lives in Read Me.txt.)
func drawGitHubChip(_ text: String, centerY: CGFloat) {
    let font = roundedFont(13, .medium)
    let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: arrowDeep])
    let tsz = str.size()
    let padH: CGFloat = 15, padV: CGFloat = 7
    let w = tsz.width + padH * 2, h = tsz.height + padV * 2
    let rect = NSRect(x: W / 2 - w / 2, y: centerY - h / 2, width: w, height: h)
    let pill = NSBezierPath(roundedRect: rect, xRadius: h / 2, yRadius: h / 2)
    brand.withAlphaComponent(0.09).setFill(); pill.fill()
    brand.withAlphaComponent(0.20).setStroke(); pill.lineWidth = 1; pill.stroke()
    str.draw(at: NSPoint(x: W / 2 - tsz.width / 2, y: centerY - tsz.height / 2))
}

/// An Amazon-style "smile" swoosh: a downward-bowing curve that tapers from a thin tail to a thick
/// head and finishes in a flared arrowhead pointing up-right. Built as a single filled ribbon (top
/// edge → arrowhead → bottom edge) so the varying width has no seam, then filled with the icon
/// gradient. Distinct from Amazon's mark: our own curvature, taper, arrowhead, and violet gradient.
func drawSmileArrow(x0: CGFloat, xEnd: CGFloat, y: CGFloat) {
    let dx = xEnd - x0
    let dip: CGFloat = 27          // how far the middle bows below the baseline (the "smile")
    let rise: CGFloat = 12         // how much the head lifts above the baseline (points up-right)
    let p0 = CGPoint(x: x0, y: y)
    let p1 = CGPoint(x: x0 + dx * 0.30, y: y + dip)
    let p2 = CGPoint(x: xEnd - dx * 0.26, y: y + dip)
    let p3 = CGPoint(x: xEnd, y: y - rise)

    func bez(_ t: CGFloat) -> CGPoint {
        let m = 1 - t
        return CGPoint(x: m*m*m*p0.x + 3*m*m*t*p1.x + 3*m*t*t*p2.x + t*t*t*p3.x,
                       y: m*m*m*p0.y + 3*m*m*t*p1.y + 3*m*t*t*p2.y + t*t*t*p3.y)
    }
    func tangent(_ t: CGFloat) -> CGVector {
        let m = 1 - t
        return CGVector(dx: 3*m*m*(p1.x-p0.x) + 6*m*t*(p2.x-p1.x) + 3*t*t*(p3.x-p2.x),
                        dy: 3*m*m*(p1.y-p0.y) + 6*m*t*(p2.y-p1.y) + 3*t*t*(p3.y-p2.y))
    }
    func normal(_ t: CGFloat) -> CGVector {
        let v = tangent(t); let m = max(hypot(v.dx, v.dy), 0.0001)
        return CGVector(dx: -v.dy / m, dy: v.dx / m)
    }

    let tHead: CGFloat = 0.72      // shaft runs 0…tHead; arrowhead spans tHead…1
    let wTail: CGFloat = 3.5       // shaft width at the tail (thin)
    let wThick: CGFloat = 17       // shaft width where it meets the arrowhead (thick)
    let headHalf: CGFloat = 22     // arrowhead half-width at its base (flares beyond the shaft)

    func halfW(_ s: CGFloat) -> CGFloat {   // s in 0…1 along the shaft
        (wTail + (wThick - wTail) * (s * s)) / 2   // quadratic ease-in: stays thin, thickens near head
    }

    let steps = 60
    var top: [CGPoint] = [], bot: [CGPoint] = []
    for i in 0...steps {
        let s = CGFloat(i) / CGFloat(steps)
        let c = bez(tHead * s), n = normal(tHead * s), hw = halfW(s)
        top.append(CGPoint(x: c.x + n.dx * hw, y: c.y + n.dy * hw))
        bot.append(CGPoint(x: c.x - n.dx * hw, y: c.y - n.dy * hw))
    }
    let cH = bez(tHead), nH = normal(tHead), tip = bez(1)
    let wingU = CGPoint(x: cH.x + nH.dx * headHalf, y: cH.y + nH.dy * headHalf)
    let wingL = CGPoint(x: cH.x - nH.dx * headHalf, y: cH.y - nH.dy * headHalf)

    let path = NSBezierPath()
    path.move(to: top[0])
    for p in top.dropFirst() { path.line(to: p) }   // top edge, tail → head
    path.line(to: wingU); path.line(to: tip); path.line(to: wingL)   // arrowhead
    for p in bot.reversed() { path.line(to: p) }     // bottom edge, head → tail
    // Rounded tail cap so the thin start is soft, not a blunt flat edge.
    let c0 = bez(0), n0 = normal(0), hw0 = halfW(0), tv = tangent(0)
    let tm = max(hypot(tv.dx, tv.dy), 0.0001)
    let back = CGVector(dx: -tv.dx / tm, dy: -tv.dy / tm)
    for k in 1...8 {
        let th = -CGFloat.pi / 2 + CGFloat.pi * CGFloat(k) / 8
        path.line(to: CGPoint(x: c0.x + cos(th) * back.dx * hw0 + sin(th) * n0.dx * hw0,
                              y: c0.y + cos(th) * back.dy * hw0 + sin(th) * n0.dy * hw0))
    }
    path.close()

    let ctx = NSGraphicsContext.current!
    ctx.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = arrowDeep.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = 9
    shadow.shadowOffset = NSSize(width: 0, height: -2)
    shadow.set()
    arrowDeep.setFill()   // solid base beneath the gradient so no anti-aliased seam shows through
    path.fill()
    ctx.restoreGraphicsState()
    // Icon gradient, clipped to the single ribbon: light tail → deep head, tilted slightly down-right.
    ctx.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [arrowLight, arrowDeep])!.draw(in: path.bounds, angle: -16)
    ctx.restoreGraphicsState()
}

let image = NSImage(size: NSSize(width: W, height: H), flipped: true) { _ in
    // Background gradient (top-left origin: top is y=0).
    NSGradient(colors: [gradTop, gradBottom])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    // Gentle brand wash across the top so the left-aligned header reads as an intentional band.
    if let wash = NSGradient(colors: [brand.withAlphaComponent(0.13), brand.withAlphaComponent(0)]) {
        wash.draw(in: NSRect(x: 0, y: 0, width: W, height: 150), angle: -90)
    }

    // Header: left-aligned brand lockup (icon + wordmark + two-line description).
    let iconSize: CGFloat = 64
    let iconX: CGFloat = 64
    let iconY: CGFloat = 40
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
    drawLeft("CloakDrop", roundedFont(29, .bold), ink, x: textX, centerY: iconY + 18)
    drawLeft("Fast multi-segment downloads with a built-in private browser for grabbing",
             roundedFont(13, .regular), secondary, x: textX + 1, centerY: iconY + 44)
    drawLeft("video, audio & files from any site — on-device, no accounts, no telemetry.",
             roundedFont(13, .regular), secondary, x: textX + 1, centerY: iconY + 62)

    // GitHub link chip, centred at the very bottom.
    drawGitHubChip("github.com/cloakyard/cloakdrop", centerY: 556)

    // Framed well behind the drag-to-install icon row (Finder overlays the real icons on top).
    drawCard(NSRect(x: 84, y: 214, width: 552, height: 168))    // install row

    // Instruction, then the tapered smile arrow bridging the app icon and the Applications alias
    // (Finder places both at y=290 inside the card).
    drawInstruction("Drag CloakDrop to your Applications folder", centerY: 182)
    drawSmileArrow(x0: 290, xEnd: 442, y: 290)

    // "Read Me.txt" (placed by Finder at y=458) sits below the card; the GitHub chip anchors the foot.

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
