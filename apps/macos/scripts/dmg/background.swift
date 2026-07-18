// Renders the CloakDrop installer DMG background.
//
// The artwork is authored in the Finder window's 760x570-point content area and rasterized at
// 2x. Finder overlays the real CloakDrop, Applications, and Install Guide icons, so this file
// only draws the brand masthead, instruction surface, connector, and ambient treatments.
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

// Shared with the light visual system on the CloakDrop site.
let canvasTop = hex("#F8FAFA")
let canvasBottom = hex("#EDF2F2")
let surface = hex("#FBFCFC")
let ink = hex("#0A1114")
let inkTwo = hex("#3E4A50")
let muted = hex("#637075")
let ocean = hex("#287F9B")
let oceanDeep = hex("#175E76")
let cyan = hex("#7FD0DC")
let hairline = hex("#173B4D")
let positive = hex("#4E9F78")

func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: weight)
}

func monoFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: weight)
}

func drawLeft(_ string: String, _ typeface: NSFont, _ color: NSColor,
              x: CGFloat, y: CGFloat, kern: CGFloat = 0) {
    let text = NSAttributedString(
        string: string,
        attributes: [.font: typeface, .foregroundColor: color, .kern: kern]
    )
    text.draw(at: NSPoint(x: x, y: y - text.size().height / 2))
}

func drawCentered(_ string: String, _ typeface: NSFont, _ color: NSColor,
                  cx: CGFloat, cy: CGFloat, kern: CGFloat = 0) {
    let text = NSAttributedString(
        string: string,
        attributes: [.font: typeface, .foregroundColor: color, .kern: kern]
    )
    let size = text.size()
    text.draw(at: NSPoint(x: cx - size.width / 2, y: cy - size.height / 2))
}

func radialGlow(cx: CGFloat, cy: CGFloat, radius: CGFloat, color: NSColor) {
    guard let gradient = NSGradient(colors: [color, color.withAlphaComponent(0)]) else { return }
    gradient.draw(
        fromCenter: NSPoint(x: cx, y: cy),
        radius: 0,
        toCenter: NSPoint(x: cx, y: cy),
        radius: radius,
        options: []
    )
}

let image = NSImage(size: NSSize(width: W, height: H), flipped: true) { _ in
    let context = NSGraphicsContext.current!
    context.imageInterpolation = .high

    // Quiet neutral canvas: enough contrast for Finder's real icon labels, with restrained brand light.
    if let background = NSGradient(colors: [canvasTop, canvasBottom]) {
        background.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
    }
    radialGlow(cx: 54, cy: -24, radius: 280, color: cyan.withAlphaComponent(0.105))
    radialGlow(cx: W + 24, cy: 392, radius: 390, color: oceanDeep.withAlphaComponent(0.048))

    // Editorial masthead. It echoes the site while remaining quieter than the install instruction.
    let headerIconSize: CGFloat = 44
    let headerIconRect = NSRect(x: 48, y: 28, width: headerIconSize, height: headerIconSize)
    radialGlow(cx: headerIconRect.midX, cy: headerIconRect.midY + 2, radius: 42,
               color: cyan.withAlphaComponent(0.14))
    if let logo = NSImage(contentsOfFile: iconPath) {
        context.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = oceanDeep.withAlphaComponent(0.14)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        logo.draw(in: headerIconRect)
        context.restoreGraphicsState()
    }
    let wordmarkText = "CloakDrop"
    let wordmark = NSMutableAttributedString(
        string: wordmarkText,
        attributes: [.font: font(24, .bold), .foregroundColor: ink, .kern: -0.55]
    )
    wordmark.addAttribute(
        .foregroundColor,
        value: ocean,
        range: (wordmarkText as NSString).range(of: "Drop")
    )
    wordmark.draw(at: NSPoint(x: 106, y: 42 - wordmark.size().height / 2))
    drawLeft("BUILT TO RESUME · FINISHED WITH PROOF", monoFont(9.2, .medium), muted,
             x: 107, y: 68, kern: 0.78)

    let systemPill = NSRect(x: 558, y: 31, width: 154, height: 34)
    let systemPillPath = NSBezierPath(roundedRect: systemPill, xRadius: 17, yRadius: 17)
    surface.withAlphaComponent(0.70).setFill()
    systemPillPath.fill()
    hairline.withAlphaComponent(0.08).setStroke()
    systemPillPath.lineWidth = 1
    systemPillPath.stroke()
    drawCentered("macOS 26+ · OPEN SOURCE", monoFont(8.2, .semibold),
                 oceanDeep.withAlphaComponent(0.88), cx: systemPill.midX, cy: systemPill.midY,
                 kern: 0.55)

    // Primary installation surface.
    let stage = NSRect(x: 40, y: 108, width: W - 80, height: 296)
    let stagePath = NSBezierPath(roundedRect: stage, xRadius: 28, yRadius: 28)
    context.saveGraphicsState()
    let cardShadow = NSShadow()
    cardShadow.shadowColor = oceanDeep.withAlphaComponent(0.10)
    cardShadow.shadowBlurRadius = 28
    cardShadow.shadowOffset = NSSize(width: 0, height: -9)
    cardShadow.set()
    surface.withAlphaComponent(0.92).setFill()
    stagePath.fill()
    context.restoreGraphicsState()

    // A nearly invisible blueprint grid relates the installer to the transfer diagrams on the site.
    context.saveGraphicsState()
    stagePath.addClip()
    hairline.withAlphaComponent(0.022).setStroke()
    for x in stride(from: stage.minX + 16, through: stage.maxX, by: 24) {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x, y: stage.minY))
        line.line(to: NSPoint(x: x, y: stage.maxY))
        line.lineWidth = 0.5
        line.stroke()
    }
    for y in stride(from: stage.minY + 16, through: stage.maxY, by: 24) {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: stage.minX, y: y))
        line.line(to: NSPoint(x: stage.maxX, y: y))
        line.lineWidth = 0.5
        line.stroke()
    }
    context.restoreGraphicsState()

    oceanDeep.withAlphaComponent(0.085).setStroke()
    let stageBorder = NSBezierPath(
        roundedRect: stage.insetBy(dx: 0.5, dy: 0.5),
        xRadius: 27.5,
        yRadius: 27.5
    )
    stageBorder.lineWidth = 1
    stageBorder.stroke()

    drawLeft("01 — INSTALL", monoFont(9.2, .semibold), oceanDeep, x: 72, y: 137, kern: 1.15)
    drawLeft("Drag CloakDrop to Applications.", font(20, .bold), ink,
             x: 72, y: 166, kern: -0.35)
    drawLeft("The app copies locally. Open it from Applications when the move finishes.",
             font(11.5, .regular), inkTwo, x: 72, y: 192)

    let rule = NSBezierPath()
    rule.move(to: NSPoint(x: 72, y: 211))
    rule.line(to: NSPoint(x: W - 72, y: 211))
    rule.lineWidth = 1
    hairline.withAlphaComponent(0.07).setStroke()
    rule.stroke()

    // Finder places the real icons at these exact centres.
    let appSlot = NSPoint(x: 204, y: 282)
    let applicationsSlot = NSPoint(x: 556, y: 282)

    for (slot, alpha) in [(appSlot, CGFloat(0.085)), (applicationsSlot, CGFloat(0.055))] {
        radialGlow(cx: slot.x, cy: slot.y + 3, radius: 76,
                   color: ocean.withAlphaComponent(alpha))
        let halo = NSRect(x: slot.x - 64, y: slot.y - 64, width: 128, height: 128)
        let haloPath = NSBezierPath(roundedRect: halo, xRadius: 31, yRadius: 31)
        ocean.withAlphaComponent(alpha * 0.26).setFill()
        haloPath.fill()
    }

    // A restrained N→1 transfer cue: multiple ranges converge into one clear install direction.
    drawCentered("ADAPTIVE COPY", monoFont(8.1, .semibold), muted.withAlphaComponent(0.76),
                 cx: W / 2, cy: 239, kern: 1.15)

    let startX: CGFloat = 300
    let mergeX: CGFloat = 387
    let endX: CGFloat = 451
    for startY in [CGFloat(268), 282, 296] {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: startX, y: startY))
        path.curve(
            to: NSPoint(x: mergeX, y: 282),
            controlPoint1: NSPoint(x: 346, y: startY),
            controlPoint2: NSPoint(x: 354, y: 282)
        )
        path.lineCapStyle = .round
        path.lineWidth = startY == 282 ? 1.8 : 1.1
        ocean.withAlphaComponent(startY == 282 ? 0.60 : 0.34).setStroke()
        path.stroke()

        let dot = NSBezierPath(ovalIn: NSRect(x: startX - 1.7, y: startY - 1.7, width: 3.4, height: 3.4))
        ocean.withAlphaComponent(0.62).setFill()
        dot.fill()
    }

    let track = NSBezierPath()
    track.move(to: NSPoint(x: mergeX, y: 282))
    track.line(to: NSPoint(x: endX, y: 282))
    track.lineCapStyle = .round
    track.lineWidth = 2.4
    ocean.withAlphaComponent(0.82).setStroke()
    track.stroke()

    let arrowHead = NSBezierPath()
    arrowHead.move(to: NSPoint(x: endX - 12, y: 271))
    arrowHead.line(to: NSPoint(x: endX, y: 282))
    arrowHead.line(to: NSPoint(x: endX - 12, y: 293))
    arrowHead.lineWidth = 2.6
    arrowHead.lineCapStyle = .round
    arrowHead.lineJoinStyle = .round
    oceanDeep.withAlphaComponent(0.90).setStroke()
    arrowHead.stroke()

    let installStatus = "DRAG ONCE · OPEN FROM APPLICATIONS"
    let installStatusFont = monoFont(8.3, .medium)
    let installStatusWidth = NSAttributedString(
        string: installStatus,
        attributes: [.font: installStatusFont, .kern: 1.1]
    ).size().width
    let statusDotX = W / 2 - installStatusWidth / 2 - 12
    let statusDot = NSBezierPath(ovalIn: NSRect(x: statusDotX, y: 370.5, width: 5, height: 5))
    positive.setFill()
    statusDot.fill()
    drawCentered(installStatus, installStatusFont, muted.withAlphaComponent(0.88),
                 cx: W / 2 + 4, cy: 373, kern: 1.1)

    // Finder supplies the guide's own label; a quiet halo keeps the lower helper action legible.
    radialGlow(cx: W / 2, cy: 464, radius: 58, color: ocean.withAlphaComponent(0.052))

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
