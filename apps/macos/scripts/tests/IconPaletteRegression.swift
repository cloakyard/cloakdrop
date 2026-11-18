import AppKit

private func require(_ condition: Bool, _ message: String) {
    if !condition {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(EXIT_FAILURE)
    }
}

// Run with swift. Additional paths may be Icon Composer exports or square Retina
// crops of the displayed icon. Both sampling points lie inside flat foreground areas.
private func sample(_ image: NSBitmapImageRep, x: Double) -> [CGFloat] {
    guard let color = image.colorAt(x: Int(x * Double(image.pixelsWide)), y: image.pixelsHigh / 2)?
        .usingColorSpace(.sRGB) else { fatalError("Cannot sample artwork in sRGB") }
    require(color.alphaComponent > 0.95, "Expected an opaque foreground pixel")
    return [color.redComponent, color.greenComponent, color.blueComponent]
}

let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../App/Resources/Assets.xcassets").standardizedFileURL
for name in ["SidebarAppIcon", "AboutAppIcon"] {
    let folder = assets.appendingPathComponent("\(name).imageset")
    struct Catalog: Decodable {
        struct Image: Decodable { let filename: String }
        let images: [Image]
    }
    let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: folder.appendingPathComponent("Contents.json")))
    for image in catalog.images { try check(folder.appendingPathComponent(image.filename)) }
}
for path in CommandLine.arguments.dropFirst() { try check(URL(fileURLWithPath: path)) }

private func check(_ url: URL) throws {
    guard let image = NSBitmapImageRep(data: try Data(contentsOf: url)) else { fatalError("Invalid image at \(url.path)") }
    let shield = sample(image, x: 0.35)
    let arrow = sample(image, x: 0.5)
    // Allow the native material to shade the pearl shield, while rejecting the
    // saturated blue previously generated for the Dark rendition.
    require(shield.allSatisfy { $0 > 0.70 } && shield.max()! - shield.min()! < 0.22,
            "Expected a pale shield in \(url.lastPathComponent), got \(shield)")
    require(arrow[0] + 0.10 < arrow[1] && arrow[1] < arrow[2] && shield[1] - arrow[1] > 0.30,
            "Expected a dark teal arrow distinct from the shield in \(url.lastPathComponent), got \(arrow)")
}
