// Renders the CloakDrop installer DMG background — the drag-to-Applications art.
//
// Source of truth for the DMG artwork; edit this to iterate. `make-dmg.sh` runs it and tags the
// output 144 dpi so it stays crisp on Retina. The layout is authored in 760x570 points and drawn
// through a flipped handler (top-left origin, y increases downward). Rasterizes at 2x.
//
//   swift background.swift <app-icon.png> <out.png>
//
// Ported from the Claude Design mock (CloakDrop Installer.dc.html): a lavender radial field, a
// left-aligned brand masthead (glowing icon + wordmark + two-line pitch), a "DRAG TO INSTALL"
// hairline divider, a soft "drag stage" card, and a dashed guide arrow into a dashed drop-zone ring.
// The three functional icons — CloakDrop.app, the Applications alias and Read Me.txt — are placed
// *by Finder* on top (positions live in make-dmg.sh), so the ring frames the real Applications folder
// and the app glow sits under the real app icon. The GitHub link lives in Read Me.txt, not the art.
// Web fonts from the mock (Space Grotesk / Inter Tight) fall back to the system face.

import AppKit

let W: CGFloat = 760
let H: CGFloat = 570

let iconPath = CommandLine.arguments[1]   // pre-glassed app icon PNG for the header
let outPath  = CommandLine.arguments[2]

// Palette lifted straight from the mock.
func hex(_ s: String, _ a: CGFloat = 1) -> NSColor {
    var h = s; if h.hasPrefix("#") { h.removeFirst() }
    var v: UInt64 = 0; Scanner(string: h).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: a)
}
let bgTop = hex("#eceafb"), bgMid = hex("#e6e4f6"), bgBot = hex("#dedbef")
let ink        = hex("#141330")   // wordmark
let desc       = hex("#6a6785")   // description
let accent     = hex("#7a6ef6")   // arrow / ring / glow periwinkle
let accentDeep = hex("#6a5ae0")   // arrowhead / chip text
let dividerCol = hex("#8a7ff0")   // "DRAG TO INSTALL"
let hairline   = hex("#786eb4")   // rgba(120,110,180,…) — borders & divider lines
let stageTop = hex("#faf9ff"), stageBot = hex("#f3f1fc")

func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont { NSFont.systemFont(ofSize: size, weight: weight) }

/// Left-aligned text, vertically centred on `y`.
func drawLeft(_ s: String, _ f: NSFont, _ c: NSColor, x: CGFloat, y: CGFloat, kern: CGFloat = 0) {
    let str = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c, .kern: kern])
    str.draw(at: NSPoint(x: x, y: y - str.size().height / 2))
}
/// Text centred on (cx, cy).
func drawCentered(_ s: String, _ f: NSFont, _ c: NSColor, cx: CGFloat, cy: CGFloat, kern: CGFloat = 0) {
    let str = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c, .kern: kern])
    let sz = str.size()
    str.draw(at: NSPoint(x: cx - sz.width / 2, y: cy - sz.height / 2))
}

/// A soft radial glow (opaque centre fading to clear), used behind icons and inside the stage.
func radialGlow(cx: CGFloat, cy: CGFloat, radius: CGFloat, color: NSColor) {
    guard let g = NSGradient(colors: [color, color.withAlphaComponent(0)]) else { return }
    g.draw(fromCenter: NSPoint(x: cx, y: cy), radius: 0, toCenter: NSPoint(x: cx, y: cy), radius: radius, options: [])
}

/// A horizontal hairline that fades to transparent at `fadeEnd` — the divider's flanks.
func fadingLine(x0: CGFloat, x1: CGFloat, y: CGFloat, solidAt fadeEnd: CGFloat) {
    let rect = NSRect(x: min(x0, x1), y: y - 0.5, width: abs(x1 - x0), height: 1)
    let solid = hairline.withAlphaComponent(0.30)
    guard let g = NSGradient(colors: fadeEnd < x0 ? [solid, solid.withAlphaComponent(0)]
                                                   : [solid.withAlphaComponent(0), solid]) else { return }
    g.draw(in: rect, angle: 0)
}

let image = NSImage(size: NSSize(width: W, height: H), flipped: true) { _ in
    let ctx = NSGraphicsContext.current!
    ctx.imageInterpolation = .high

    // Lavender radial field, centred on the top edge (matches the mock's 50% 0% radial).
    bgBot.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
    if let bg = NSGradient(colorsAndLocations: (bgTop, 0.0), (bgMid, 0.42), (bgBot, 1.0)) {
        bg.draw(fromCenter: NSPoint(x: W / 2, y: 0), radius: 0,
                toCenter: NSPoint(x: W / 2, y: 0), radius: 720, options: [.drawsAfterEndingLocation])
    }

    // ── Masthead: glowing app icon + wordmark + two-line pitch ──────────────────────────────────
    let hIcon: CGFloat = 60, hIconX: CGFloat = 60, hIconY: CGFloat = 42
    let hIconCenter = NSPoint(x: hIconX + hIcon / 2, y: hIconY + hIcon / 2)
    radialGlow(cx: hIconCenter.x, cy: hIconCenter.y + 2, radius: 58, color: hex("#7868f0", 0.34))
    if let logo = NSImage(contentsOfFile: iconPath) {
        ctx.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = accentDeep.withAlphaComponent(0.42)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        logo.draw(in: NSRect(x: hIconX, y: hIconY, width: hIcon, height: hIcon))
        ctx.restoreGraphicsState()
    }
    let textX = hIconX + hIcon + 20
    drawLeft("CloakDrop", font(29, .bold), ink, x: textX, y: hIconY + 16, kern: -0.4)
    drawLeft("Fast multi-segment downloads with a built-in private browser for grabbing",
             font(13.5, .regular), desc, x: textX + 1, y: hIconY + 40)
    drawLeft("video, audio & files from any site — on-device, no accounts, no telemetry.",
             font(13.5, .regular), desc, x: textX + 1, y: hIconY + 60)

    // ── "DRAG TO INSTALL" divider ───────────────────────────────────────────────────────────────
    let dY: CGFloat = 152
    let dText = "DRAG TO INSTALL", dFont = font(12, .semibold), dKern: CGFloat = 2.4
    let dW = NSAttributedString(string: dText, attributes: [.font: dFont, .kern: dKern]).size().width
    let gap: CGFloat = 16
    fadingLine(x0: 130, x1: W / 2 - dW / 2 - gap, y: dY, solidAt: 130)
    fadingLine(x0: W / 2 + dW / 2 + gap, x1: W - 130, y: dY, solidAt: W - 130)
    drawCentered(dText, dFont, dividerCol, cx: W / 2, cy: dY, kern: dKern)

    // ── Drag stage (Finder overlays the real app icon + Applications alias inside it) ────────────
    let stage = NSRect(x: 56, y: 176, width: W - 112, height: 200)   // y 176…376
    let stagePath = NSBezierPath(roundedRect: stage, xRadius: 20, yRadius: 20)
    NSGradient(colors: [stageTop, stageBot])!.draw(in: stagePath, angle: -90)
    ctx.saveGraphicsState()
    stagePath.addClip()
    radialGlow(cx: stage.minX + stage.width * 0.22, cy: stage.midY, radius: stage.width * 0.55,
               color: hex("#7e6ef6", 0.12))
    ctx.restoreGraphicsState()
    hairline.withAlphaComponent(0.16).setStroke()
    let border = NSBezierPath(roundedRect: stage.insetBy(dx: 0.5, dy: 0.5), xRadius: 20, yRadius: 20)
    border.lineWidth = 1; border.stroke()

    // Slots — Finder places both icons at y=258 (centres x=200 and x=560).
    let appSlot = NSPoint(x: 200, y: 258), appsSlot = NSPoint(x: 560, y: 258)

    // Soft glow grounding the real app icon.
    radialGlow(cx: appSlot.x, cy: appSlot.y + 4, radius: 66, color: hex("#5c4adc", 0.30))

    // Dashed drop-zone ring framing the real Applications folder.
    let ring = NSBezierPath(ovalIn: NSRect(x: appsSlot.x - 56, y: appsSlot.y - 56, width: 112, height: 112))
    ring.lineWidth = 2
    ring.setLineDash([4, 9], count: 2, phase: 0)
    accent.withAlphaComponent(0.45).setStroke()
    ring.stroke()

    // Dashed guide arrow arcing from the app toward the drop zone, tipped with a chevron.
    // Kept short and centred in the gap (not spanning it) to match the mock.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 316, y: 272))
    arrow.curve(to: NSPoint(x: 430, y: 250), controlPoint1: NSPoint(x: 356, y: 276), controlPoint2: NSPoint(x: 398, y: 254))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.setLineDash([8, 8], count: 2, phase: 0)
    accent.setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 430, y: 239))
    head.line(to: NSPoint(x: 448, y: 250))
    head.line(to: NSPoint(x: 433, y: 265))
    head.lineWidth = 3.4
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    accentDeep.setStroke()
    head.stroke()

    // ── Footer: Read Me.txt is placed by Finder (bottom-left); its GitHub link lives in the file ─
    // (No GitHub chip in the art — the repo URL is in Read Me.txt.)

    return true
}

// Rasterize to a 2x bitmap; make-dmg.sh tags it 144 dpi so Finder renders it crisp at 760x570 pt.
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
