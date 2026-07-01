import Foundation
import DownloadModels

/// Maps a file name to a specific SF Symbol by its extension, so an `.iso` reads as a disc
/// and a `.pdf` as a document — finer-grained than the broad category icon, while staying
/// SF-Symbols-only per the design language. Falls back to the category glyph.
///
/// Icons are rendered monochrome (`.primary`, white when selected) by the views, so they
/// stay legible on the selection highlight and read as a clean, native set.
enum FileIcon {
    static func symbol(forFileName fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if let specific = symbolTable[ext] { return specific }
        return FileCategory.classify(fileName: fileName).systemImage
    }

    private static let symbolTable: [String: String] = [
        // Disk images
        "iso": "opticaldisc", "dmg": "opticaldisc", "img": "opticaldisc", "vhd": "opticaldisc",
        // Documents
        "pdf": "doc.richtext",
        "doc": "doc.text", "docx": "doc.text", "rtf": "doc.text", "txt": "doc.text",
        "pages": "doc.text", "md": "doc.plaintext",
        "xls": "tablecells", "xlsx": "tablecells", "numbers": "tablecells", "csv": "tablecells",
        "ppt": "rectangle.on.rectangle", "pptx": "rectangle.on.rectangle", "key": "rectangle.on.rectangle",
        "epub": "book", "mobi": "book",
        // Archives & installers
        "zip": "archivebox", "rar": "archivebox", "7z": "archivebox",
        "tar": "archivebox", "gz": "archivebox", "tgz": "archivebox", "bz2": "archivebox",
        "xz": "archivebox", "zst": "archivebox",
        "pkg": "shippingbox", "msi": "shippingbox", "deb": "shippingbox", "rpm": "shippingbox",
        "app": "app", "exe": "app", "appimage": "app",
        // Code & data
        "json": "curlybraces", "xml": "curlybraces", "yaml": "curlybraces", "yml": "curlybraces",
        "html": "chevron.left.forwardslash.chevron.right", "js": "chevron.left.forwardslash.chevron.right",
        "css": "chevron.left.forwardslash.chevron.right", "swift": "swift",
        "sh": "terminal", "command": "terminal",
        // Fonts
        "ttf": "textformat", "otf": "textformat", "woff": "textformat", "woff2": "textformat"
    ]
}
