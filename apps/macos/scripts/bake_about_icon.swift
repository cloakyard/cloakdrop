import AppKit

// Bakes the About-page app icon: a *glassy* copy of the app icon as macOS composites it for the
// Dock/Finder (Tahoe's Liquid Glass — depth, gloss, specular highlight). SwiftUI's
// `Image("AboutAppIcon")` draws a raw PNG and does NOT apply the OS glass treatment, so without this
// the About page would look flatter than the real icon in the Dock. The flat AppIcon.appiconset stays
// the source of truth; this only produces the pre-glassed copy the About view draws.
//
// Run AFTER building + installing the app (the OS composites the glassy icon from the installed
// bundle), from the repo root:
//
//   swift scripts/bake_about_icon.swift [/Applications/CloakDrop.app] [AboutAppIcon.imageset dir]
//
// Regenerate whenever the app icon (AppIcon.appiconset) changes.

let appPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/Applications/CloakDrop.app"
let outDir = CommandLine.arguments.count > 2 ? CommandLine.arguments[2]
    : "App/Resources/Assets.xcassets/AboutAppIcon.imageset"

let icon = NSWorkspace.shared.icon(forFile: appPath)

func bake(_ size: Int, _ filename: String) {
    let target = NSSize(width: size, height: size)
    let img = NSImage(size: target)
    img.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    icon.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
    img.unlockFocus()
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encode failed") }
    try! png.write(to: URL(fileURLWithPath: "\(outDir)/\(filename)"))
    print("wrote \(outDir)/\(filename) (\(size)px)")
}

bake(256, "about_icon_256.png")   // @1x
bake(512, "about_icon_512.png")   // @2x
