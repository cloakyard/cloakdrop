import Foundation

/// A file-type bucket used for sidebar grouping and auto-categorization.
///
/// Categories are derived from a file's extension. The mapping is intentionally
/// conservative — unknown types fall back to `.other` rather than being guessed.
public enum FileCategory: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case video
    case audio
    case document
    case archive
    case program
    case image
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .video: return "Video"
        case .audio: return "Audio"
        case .document: return "Documents"
        case .archive: return "Archives"
        case .program: return "Programs"
        case .image: return "Images"
        case .other: return "Other"
        }
    }

    /// SF Symbol used to represent this category in the UI.
    public var systemImage: String {
        switch self {
        case .video: return "film"
        case .audio: return "music.note"
        case .document: return "doc.text"
        case .archive: return "archivebox"
        case .program: return "shippingbox"
        case .image: return "photo"
        case .other: return "doc"
        }
    }

    /// Classify a file name (or path) by its extension.
    public static func classify(fileName: String) -> FileCategory {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .other }
        for (category, extensions) in extensionTable where extensions.contains(ext) {
            return category
        }
        return .other
    }

    private static let extensionTable: [(FileCategory, Set<String>)] = [
        (.video, ["mp4", "mkv", "mov", "avi", "wmv", "flv", "webm", "m4v", "mpg", "mpeg", "ts", "m2ts"]),
        (.audio, ["mp3", "aac", "flac", "wav", "m4a", "ogg", "opus", "wma", "aiff", "alac"]),
        (.document, ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "epub", "pages", "numbers", "key", "csv", "md"]),
        (.archive, ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "iso", "tgz", "zst"]),
        (.program, ["app", "pkg", "exe", "msi", "deb", "rpm", "appimage", "jar", "bin", "run"]),
        (.image, ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp", "svg", "raw", "psd"])
    ]
}
