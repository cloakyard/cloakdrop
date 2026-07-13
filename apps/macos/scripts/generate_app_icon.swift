import AppKit

// Regenerates the 1024×1024 master app icon. Run, then resize into the appiconset:
//
//   swift scripts/generate_app_icon.swift /tmp/icon_1024.png
//   for s in 16 32 64 128 256 512 1024; do
//     sips -z $s $s /tmp/icon_1024.png --out App/Resources/Assets.xcassets/AppIcon.appiconset/icon_$s.png
//   done
//
// Design: a "deep ocean" squircle — bright turquoise melting through ocean-blue into deep midnight
// navy (à la Freeform) — with a white shield/droplet and a single downward arrow.

let size = 1024.0
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Rounded-square background with a deep-ocean gradient: bright turquoise (top-left) → ocean-blue →
// deep midnight navy (bottom-right). The dark bottom makes the white droplet pop.
let inset = size * 0.06
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let corner = rect.width * 0.2237   // squircle-ish radius
let bgPath = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
ctx.addPath(bgPath)
ctx.clip()

let colors = [
    CGColor(red: 0.298, green: 0.788, blue: 0.796, alpha: 1.0), // bright turquoise #4CC9CB
    CGColor(red: 0.165, green: 0.482, blue: 0.608, alpha: 1.0), // ocean blue #2A7B9B
    CGColor(red: 0.094, green: 0.165, blue: 0.333, alpha: 1.0)  // deep midnight navy #182A55
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

ctx.resetClip()

// White droplet centered, with a downward arrow cut out.
let cx = size / 2
func droplet(scale: CGFloat) -> CGPath {
    // Teardrop: pointed top, round bottom.
    let w = size * 0.30 * scale
    let topY = size * 0.74
    let bottomY = size * 0.26
    let p = CGMutablePath()
    let tip = CGPoint(x: cx, y: topY)
    let bottom = CGPoint(x: cx, y: bottomY)
    let r = w
    let center = CGPoint(x: cx, y: bottomY + r)
    p.move(to: tip)
    p.addCurve(to: CGPoint(x: cx + r, y: center.y),
               control1: CGPoint(x: cx + r * 0.55, y: topY - (topY - center.y) * 0.45),
               control2: CGPoint(x: cx + r, y: center.y + r * 0.6))
    p.addArc(center: center, radius: r, startAngle: 0, endAngle: .pi, clockwise: true)
    p.addCurve(to: tip,
               control1: CGPoint(x: cx - r, y: center.y + r * 0.6),
               control2: CGPoint(x: cx - r * 0.55, y: topY - (topY - center.y) * 0.45))
    p.closeSubpath()
    _ = bottom
    return p
}

ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.18))
ctx.addPath(droplet(scale: 1.0))
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// Downward arrow inside the droplet, tinted with the gradient color. Built as ONE closed
// polygon (stem + head in a single subpath) so there are no internal edges — an earlier
// two-subpath version (rect + triangle) had opposite windings, and the default nonzero fill
// canceled their overlap into a thin unfilled "white line" across the arrow.
let arrowColor = CGColor(red: 0.122, green: 0.392, blue: 0.502, alpha: 1.0) // deep-ocean teal #1F6480 — a vivid brand-hue arrow (the teal analog of the original indigo arrow), not a near-black navy
let aW = size * 0.16                 // full arrowhead width
let aTop = size * 0.62               // top of the stem
let aBottom = size * 0.40            // arrow tip (points down)
let halfStem = (aW * 0.34) / 2       // half the stem width
let halfHead = aW / 2
let shoulderY = aBottom + aW * 0.55  // where the head's shoulders meet the stem
let arrow = CGMutablePath()
arrow.move(to: CGPoint(x: cx - halfStem, y: aTop))          // stem top-left
arrow.addLine(to: CGPoint(x: cx + halfStem, y: aTop))       // stem top-right
arrow.addLine(to: CGPoint(x: cx + halfStem, y: shoulderY))  // down to right shoulder
arrow.addLine(to: CGPoint(x: cx + halfHead, y: shoulderY))  // out to head's right corner
arrow.addLine(to: CGPoint(x: cx, y: aBottom))               // down to the tip
arrow.addLine(to: CGPoint(x: cx - halfHead, y: shoulderY))  // up to head's left corner
arrow.addLine(to: CGPoint(x: cx - halfStem, y: shoulderY))  // in to left shoulder
arrow.closeSubpath()                                        // back up to stem top-left
ctx.addPath(arrow)
ctx.setFillColor(arrowColor)
ctx.fillPath()

NSGraphicsContext.restoreGraphicsState()

let outURL = URL(fileURLWithPath: CommandLine.arguments[1])
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: outURL)
print("wrote \(outURL.path)")
