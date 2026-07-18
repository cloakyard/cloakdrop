// Applies a purpose-built icon to the text install guide staged inside the DMG.
//
//   swift guide-icon.swift <guide-file>

import AppKit

guard CommandLine.arguments.count == 2 else {
    fatalError("usage: swift guide-icon.swift <guide-file>")
}

let targetPath = CommandLine.arguments[1]
let iconSize = NSSize(width: 512, height: 512)

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

let accent = hex("#287F9B")
let accentStrong = hex("#175E76")
let surface = hex("#FBFCFC")
let surfaceTwo = hex("#E6EFF1")

let icon = NSImage(size: iconSize, flipped: true) { _ in
    let context = NSGraphicsContext.current!
    context.imageInterpolation = .high

    let plate = NSRect(x: 50, y: 42, width: 412, height: 412)
    let platePath = NSBezierPath(roundedRect: plate, xRadius: 92, yRadius: 92)

    context.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = accentStrong.withAlphaComponent(0.20)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    if let gradient = NSGradient(colors: [surface, surfaceTwo]) {
        gradient.draw(in: platePath, angle: -90)
    }
    context.restoreGraphicsState()

    accentStrong.withAlphaComponent(0.15).setStroke()
    platePath.lineWidth = 2
    platePath.stroke()

    if let book = NSImage(systemSymbolName: "book.closed.fill", accessibilityDescription: nil) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 174, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [accent]))
        book.withSymbolConfiguration(configuration)?.draw(
            in: NSRect(x: 137, y: 132, width: 238, height: 210)
        )
    }

    let badge = NSRect(x: 323, y: 317, width: 94, height: 94)
    let badgePath = NSBezierPath(ovalIn: badge)
    context.saveGraphicsState()
    let badgeShadow = NSShadow()
    badgeShadow.shadowColor = accentStrong.withAlphaComponent(0.22)
    badgeShadow.shadowBlurRadius = 12
    badgeShadow.shadowOffset = NSSize(width: 0, height: -5)
    badgeShadow.set()
    accentStrong.setFill()
    badgePath.fill()
    context.restoreGraphicsState()

    if let question = NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 42, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        question.withSymbolConfiguration(configuration)?.draw(
            in: NSRect(x: 346, y: 339, width: 48, height: 50)
        )
    }

    return true
}

guard NSWorkspace.shared.setIcon(icon, forFile: targetPath, options: []) else {
    fatalError("could not apply the custom icon to \(targetPath)")
}

print("applied guide icon to \(targetPath)")
