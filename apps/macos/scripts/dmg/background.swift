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

let canvasTop = hex("#F9FBFC")
let canvasBottom = hex("#EEF4F7")
let ink = hex("#14212B")
let muted = hex("#60727E")
let ocean = hex("#2485A2")
let oceanDeep = hex("#174C6B")
let cyan = hex("#62D4D7")
let hairline = hex("#173B4D")

func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: weight)
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

func fadingLine(x0: CGFloat, x1: CGFloat, y: CGFloat, fadeTowardRight: Bool) {
    let lineColor = hairline.withAlphaComponent(0.12)
    guard let gradient = NSGradient(colors: fadeTowardRight
        ? [lineColor.withAlphaComponent(0), lineColor]
        : [lineColor, lineColor.withAlphaComponent(0)]) else { return }
    gradient.draw(
        in: NSRect(x: x0, y: y - 0.5, width: x1 - x0, height: 1),
        angle: 0
    )
}

let image = NSImage(size: NSSize(width: W, height: H), flipped: true) { _ in
    let context = NSGraphicsContext.current!
    context.imageInterpolation = .high

    // Quiet ocean canvas: neutral enough for Finder labels, with restrained brand light.
    if let background = NSGradient(colors: [canvasTop, canvasBottom]) {
        background.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
    }
    radialGlow(cx: 70, cy: -18, radius: 300, color: cyan.withAlphaComponent(0.10))
    radialGlow(cx: W + 18, cy: 420, radius: 390, color: oceanDeep.withAlphaComponent(0.045))

    // Compact masthead. The real Finder app icon remains the visual focus in the install surface.
    let headerIconSize: CGFloat = 48
    let headerIconRect = NSRect(x: 52, y: 31, width: headerIconSize, height: headerIconSize)
    radialGlow(cx: headerIconRect.midX, cy: headerIconRect.midY + 2, radius: 42,
               color: cyan.withAlphaComponent(0.15))
    if let logo = NSImage(contentsOfFile: iconPath) {
        context.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = oceanDeep.withAlphaComponent(0.16)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        logo.draw(in: headerIconRect)
        context.restoreGraphicsState()
    }
    drawLeft("CloakDrop", font(27, .semibold), ink, x: 116, y: 48, kern: -0.45)
    drawLeft("Fast, private downloads — entirely on your Mac.", font(12.5, .regular), muted,
             x: 117, y: 77)

    // Primary installation surface.
    let stage = NSRect(x: 48, y: 116, width: W - 96, height: 276)
    let stagePath = NSBezierPath(roundedRect: stage, xRadius: 26, yRadius: 26)
    context.saveGraphicsState()
    let cardShadow = NSShadow()
    cardShadow.shadowColor = oceanDeep.withAlphaComponent(0.085)
    cardShadow.shadowBlurRadius = 24
    cardShadow.shadowOffset = NSSize(width: 0, height: -8)
    cardShadow.set()
    NSColor.white.withAlphaComponent(0.86).setFill()
    stagePath.fill()
    context.restoreGraphicsState()

    oceanDeep.withAlphaComponent(0.075).setStroke()
    let stageBorder = NSBezierPath(
        roundedRect: stage.insetBy(dx: 0.5, dy: 0.5),
        xRadius: 25.5,
        yRadius: 25.5
    )
    stageBorder.lineWidth = 1
    stageBorder.stroke()

    drawCentered("Install CloakDrop", font(16.5, .semibold), ink, cx: W / 2, cy: 151, kern: -0.15)
    drawCentered("Drag the app to Applications", font(12.5, .regular), muted, cx: W / 2, cy: 177)

    // Finder places the real icons at these exact centres.
    let appSlot = NSPoint(x: 204, y: 282)
    let applicationsSlot = NSPoint(x: 556, y: 282)

    radialGlow(cx: appSlot.x, cy: appSlot.y + 3, radius: 72,
               color: ocean.withAlphaComponent(0.12))

    let applicationsPlate = NSRect(
        x: applicationsSlot.x - 60,
        y: applicationsSlot.y - 60,
        width: 120,
        height: 112
    )
    let applicationsPlatePath = NSBezierPath(
        roundedRect: applicationsPlate,
        xRadius: 29,
        yRadius: 29
    )
    ocean.withAlphaComponent(0.038).setFill()
    applicationsPlatePath.fill()
    ocean.withAlphaComponent(0.11).setStroke()
    applicationsPlatePath.lineWidth = 1
    applicationsPlatePath.stroke()

    // One coherent motion cue: a soft track and crisp ocean-blue chevron.
    let track = NSBezierPath()
    track.move(to: NSPoint(x: 325, y: 282))
    track.line(to: NSPoint(x: 435, y: 282))
    track.lineCapStyle = .round
    track.lineWidth = 8
    ocean.withAlphaComponent(0.055).setStroke()
    track.stroke()

    track.lineWidth = 2.25
    ocean.withAlphaComponent(0.72).setStroke()
    track.stroke()

    let arrowHead = NSBezierPath()
    arrowHead.move(to: NSPoint(x: 423, y: 271))
    arrowHead.line(to: NSPoint(x: 435, y: 282))
    arrowHead.line(to: NSPoint(x: 423, y: 293))
    arrowHead.lineWidth = 2.5
    arrowHead.lineCapStyle = .round
    arrowHead.lineJoinStyle = .round
    oceanDeep.withAlphaComponent(0.90).setStroke()
    arrowHead.stroke()

    // The Finder-rendered Install Guide icon is centred below the primary task.
    let guideCaption = "INSTALL GUIDE"
    let guideFont = font(9.5, .semibold)
    let guideKern: CGFloat = 1.7
    let captionWidth = NSAttributedString(
        string: guideCaption,
        attributes: [.font: guideFont, .kern: guideKern]
    ).size().width
    let captionGap: CGFloat = 15
    fadingLine(x0: 94, x1: W / 2 - captionWidth / 2 - captionGap, y: 419, fadeTowardRight: true)
    fadingLine(x0: W / 2 + captionWidth / 2 + captionGap, x1: W - 94, y: 419, fadeTowardRight: false)
    drawCentered(guideCaption, guideFont, muted.withAlphaComponent(0.78),
                 cx: W / 2, cy: 419, kern: guideKern)
    radialGlow(cx: W / 2, cy: 483, radius: 58, color: ocean.withAlphaComponent(0.055))

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
    colorSpaceName: .deviceRGB,
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
