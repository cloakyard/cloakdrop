import Foundation

// Exports flattened About-page artwork and legacy asset-catalog fallbacks from the
// native Icon Composer document.
// App/Resources/AppIcon.icon is the macOS launcher source of truth: Xcode compiles its
// layered Liquid Glass material directly and generates the platform-specific icon sizes.
// The About page can't render an Icon Composer document inside SwiftUI, so it consumes
// deterministic Default-rendition exports instead. The AppIcon.appiconset copies remain
// aligned as fallbacks for tooling that still expects conventional PNG slots.
//
// Run from apps/macos with Xcode 26.4 or later:
//
//   swift scripts/generate_app_icon.swift
//
// Regenerate whenever AppIcon.icon changes.

let fm = FileManager.default
let iconDocument = "App/Resources/AppIcon.icon"
guard fm.fileExists(atPath: iconDocument) else {
    fatalError("missing \(iconDocument) — run this from apps/macos")
}

func iconComposerTool() -> String {
    let xcodeSelect = Process()
    let pipe = Pipe()
    xcodeSelect.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    xcodeSelect.arguments = ["-p"]
    xcodeSelect.standardOutput = pipe
    try? xcodeSelect.run()
    xcodeSelect.waitUntilExit()

    let developerDirectory = String(
        data: pipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    )?.trimmingCharacters(in: .whitespacesAndNewlines)

    guard xcodeSelect.terminationStatus == 0, let developerDirectory else {
        fatalError("could not locate the active Xcode developer directory")
    }

    let xcodeContents = URL(fileURLWithPath: developerDirectory)
        .deletingLastPathComponent()
    let tool = xcodeContents
        .appendingPathComponent("Applications/Icon Composer.app/Contents/Executables/ictool")
        .path
    guard fm.isExecutableFile(atPath: tool) else {
        fatalError("Icon Composer's ictool is unavailable — install or select Xcode 26.4 or later")
    }
    return tool
}

let ictool = iconComposerTool()

func render(_ size: Int, to path: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: ictool)
    p.arguments = [
        iconDocument,
        "--export-image",
        "--output-file", path,
        "--platform", "macOS",
        "--rendition", "Default",
        "--width", "\(size)",
        "--height", "\(size)",
        "--scale", "1",
    ]
    do {
        try p.run()
        p.waitUntilExit()
    } catch {
        fatalError("could not run Icon Composer export: \(error)")
    }
    guard p.terminationStatus == 0 else {
        fatalError("Icon Composer failed writing \(path)")
    }
    print("wrote \(path)")
}

let aboutIcon = "App/Resources/Assets.xcassets/AboutAppIcon.imageset"
let fallbackIcon = "App/Resources/Assets.xcassets/AppIcon.appiconset"

render(256, to: "\(aboutIcon)/about_icon_256.png")
render(512, to: "\(aboutIcon)/about_icon_512.png")

for size in [16, 32, 64, 128, 256, 512, 1024] {
    render(size, to: "\(fallbackIcon)/icon_\(size).png")
}

print("done — flattened fallbacks exported from \(iconDocument); Xcode compiles the launcher icon")
