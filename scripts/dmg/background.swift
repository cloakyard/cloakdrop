// Renders the CloakDrop installer DMG background — the elegant drag-to-Applications art.
//
// Source of truth for the DMG artwork; edit this to iterate. `make-dmg.sh` runs it and tags the
// output 144 dpi so it stays crisp on Retina. The layout is authored in 720x584 points and drawn
// through a flipped handler (top-left origin, y increases downward). Rasterizes at 2x.
//
//   swift background.swift <app-icon.png> <out.png>
//
// Off-centre by design: a left-aligned brand lockup (icon + SF Rounded wordmark + a two-line
// description) in a soft brand wash across the top, a GitHub link chip at the foot, then the centred
// drag-to-install card with an Amazon-style "smile" arrow (the real Amazon swoosh geometry, recoloured
// in our periwinkle→indigo — the same gradient as the app icon).

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

/// Minimal SVG-path evaluator (M/m L/l H/h V/v C/c Z/z — enough for the Amazon swoosh), appending to
/// `path` after mapping each point through (x·scale+ox, y·scale+oy). Both the SVG and our render use
/// a y-down space, so no axis flip is needed.
func appendSVGPath(_ d: String, to path: NSBezierPath, scale: CGFloat, ox: CGFloat, oy: CGFloat) {
    var tokens: [String] = [], num = ""
    for ch in d {
        if ch.isLetter {
            if !num.isEmpty { tokens.append(num); num = "" }
            tokens.append(String(ch))
        } else if ch == "-" {
            if !num.isEmpty { tokens.append(num) }
            num = "-"
        } else if ch == " " || ch == "," || ch == "\n" || ch == "\t" {
            if !num.isEmpty { tokens.append(num); num = "" }
        } else {
            num.append(ch)
        }
    }
    if !num.isEmpty { tokens.append(num) }

    func tf(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * scale, y: oy + y * scale) }
    var i = 0, cmd = "", cur = CGPoint.zero, sub = CGPoint.zero
    func n() -> CGFloat { let v = CGFloat(Double(tokens[i]) ?? 0); i += 1; return v }
    while i < tokens.count {
        if Double(tokens[i]) == nil { cmd = tokens[i]; i += 1 }   // else: implicit repeat of last command
        switch cmd {
        case "M": cur = CGPoint(x: n(), y: n()); sub = cur; path.move(to: tf(cur.x, cur.y)); cmd = "L"
        case "m": cur = CGPoint(x: cur.x + n(), y: cur.y + n()); sub = cur; path.move(to: tf(cur.x, cur.y)); cmd = "l"
        case "L": cur = CGPoint(x: n(), y: n()); path.line(to: tf(cur.x, cur.y))
        case "l": cur = CGPoint(x: cur.x + n(), y: cur.y + n()); path.line(to: tf(cur.x, cur.y))
        case "H": cur.x = n(); path.line(to: tf(cur.x, cur.y))
        case "h": cur.x += n(); path.line(to: tf(cur.x, cur.y))
        case "V": cur.y = n(); path.line(to: tf(cur.x, cur.y))
        case "v": cur.y += n(); path.line(to: tf(cur.x, cur.y))
        case "C":
            let c1 = CGPoint(x: n(), y: n()), c2 = CGPoint(x: n(), y: n()), e = CGPoint(x: n(), y: n())
            path.curve(to: tf(e.x, e.y), controlPoint1: tf(c1.x, c1.y), controlPoint2: tf(c2.x, c2.y)); cur = e
        case "c":
            let c1 = CGPoint(x: cur.x + n(), y: cur.y + n()), c2 = CGPoint(x: cur.x + n(), y: cur.y + n())
            let e = CGPoint(x: cur.x + n(), y: cur.y + n())
            path.curve(to: tf(e.x, e.y), controlPoint1: tf(c1.x, c1.y), controlPoint2: tf(c2.x, c2.y)); cur = e
        case "Z", "z": path.close(); cur = sub
        default: i += 1
        }
    }
}

// The real Amazon swoosh, straight from the logo SVG (viewBox units): the crescent "smile" body and
// its up-right arrowhead flick. Rounded, tapered, concave-under arrowhead — not a sharp spike. We
// recolour it in our violet gradient (the brand tweak) and drop the letter glyph.
let amazonSmileBody = "M 0.164 64.582 c 0.273 -0.436 0.709 -0.464 1.309 -0.082 c 13.636 7.909 28.473 11.864 44.509 11.864 c 10.691 0 21.245 -1.991 31.664 -5.973 c 0.273 -0.109 0.668 -0.273 1.186 -0.491 c 0.518 -0.218 0.886 -0.382 1.105 -0.491 c 0.818 -0.327 1.459 -0.164 1.923 0.491 c 0.464 0.655 0.314 1.255 -0.45 1.8 c -0.982 0.709 -2.236 1.527 -3.764 2.455 c -4.691 2.782 -9.927 4.936 -15.709 6.464 C 56.155 82.145 50.509 82.909 45 82.909 c -8.509 0 -16.555 -1.486 -24.136 -4.459 c -7.582 -2.973 -14.373 -7.159 -20.373 -12.559 C 0.164 65.618 0 65.345 0 65.073 C 0 64.909 0.054 64.745 0.164 64.582 z"
let amazonArrowhead = "M 73.227 65.973 c 0.109 -0.218 0.273 -0.436 0.491 -0.655 c 1.364 -0.927 2.673 -1.555 3.927 -1.882 c 2.073 -0.545 4.091 -0.845 6.055 -0.9 c 0.545 -0.055 1.064 -0.027 1.555 0.082 c 2.455 0.218 3.927 0.627 4.418 1.227 C 89.891 64.173 90 64.664 90 65.318 v 0.573 c 0 1.909 -0.518 4.159 -1.555 6.75 c -1.036 2.591 -2.482 4.677 -4.336 6.259 c -0.273 0.218 -0.518 0.327 -0.736 0.327 c -0.109 0 -0.218 -0.027 -0.327 -0.082 c -0.327 -0.164 -0.409 -0.464 -0.245 -0.9 c 2.018 -4.745 3.027 -8.045 3.027 -9.9 c 0 -0.6 -0.109 -1.036 -0.327 -1.309 c -0.545 -0.655 -2.073 -0.982 -4.582 -0.982 c -0.927 0 -2.018 0.055 -3.273 0.164 c -1.364 0.164 -2.618 0.327 -3.764 0.491 c -0.327 0 -0.545 -0.055 -0.655 -0.164 c -0.109 -0.109 -0.136 -0.218 -0.082 -0.327 C 73.145 66.164 73.173 66.082 73.227 65.973 z"

/// The Amazon-style swoosh, positioned so its ~90×21 logo box spans [x0…xEnd] with the tail/arrowhead
/// ends resting near baseline `y`, filled with the icon's periwinkle→indigo gradient.
func drawSmileArrow(x0: CGFloat, xEnd: CGFloat, y: CGFloat) {
    let scale = (xEnd - x0) / 90.0
    let ox = x0
    let oy = y - 65 * scale            // path y≈65 is the ends' level; the belly bows below it

    let path = NSBezierPath()
    path.windingRule = .nonZero
    appendSVGPath(amazonSmileBody, to: path, scale: scale, ox: ox, oy: oy)
    appendSVGPath(amazonArrowhead, to: path, scale: scale, ox: ox, oy: oy)

    let ctx = NSGraphicsContext.current!
    ctx.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = arrowDeep.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 8
    shadow.shadowOffset = NSSize(width: 0, height: -2)
    shadow.set()
    arrowDeep.setFill()   // solid base beneath the gradient so no anti-aliased seam shows through
    path.fill()
    ctx.restoreGraphicsState()
    // Icon gradient, clipped to the swoosh: light tail (left) → deep head (right).
    ctx.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [arrowLight, arrowDeep])!.draw(in: path.bounds, angle: -6)
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

    // Instruction, then the Amazon-style smile arrow bridging the app icon and the Applications alias
    // (Finder places both at y=290 inside the card).
    drawInstruction("Drag CloakDrop to your Applications folder", centerY: 182)
    drawSmileArrow(x0: 286, xEnd: 449, y: 293)

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
