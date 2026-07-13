import Foundation

// Renders the macOS app icon (AppIcon.appiconset) and the About-page icon
// (AboutAppIcon.imageset) from the single, shared, *glassified* brand mark at
// ../../assets/logo/cloakdrop.svg — the source of truth for the CloakDrop logo on both the
// app and the website (see /assets/README.md). That SVG already carries the Liquid-Glass
// treatment (gradient tile, frosted shield, specular sheen, rim light, depth), so this
// script only rasterises it into the sizes Xcode's asset catalog needs; there is no
// separate flat/OS-composited step anymore.
//
// Run from apps/macos (needs librsvg — `brew install librsvg`):
//
//   swift scripts/generate_app_icon.swift
//
// Regenerate whenever /assets/logo/cloakdrop.svg changes.

let fm = FileManager.default
let svg = "../../assets/logo/cloakdrop.svg"
guard fm.fileExists(atPath: svg) else {
    fatalError("missing \(svg) — run this from apps/macos")
}

func render(_ size: Int, to path: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["rsvg-convert", "-w", "\(size)", "-h", "\(size)", svg, "-o", path]
    do {
        try p.run()
        p.waitUntilExit()
    } catch {
        fatalError("rsvg-convert not found — install it with `brew install librsvg`. (\(error))")
    }
    guard p.terminationStatus == 0 else { fatalError("rsvg-convert failed writing \(path)") }
    print("wrote \(path)")
}

let appIcon = "App/Resources/Assets.xcassets/AppIcon.appiconset"
let aboutIcon = "App/Resources/Assets.xcassets/AboutAppIcon.imageset"

for size in [16, 32, 64, 128, 256, 512, 1024] {
    render(size, to: "\(appIcon)/icon_\(size).png")
}
render(256, to: "\(aboutIcon)/about_icon_256.png")
render(512, to: "\(aboutIcon)/about_icon_512.png")

print("done — app + About icon rendered from \(svg)")
