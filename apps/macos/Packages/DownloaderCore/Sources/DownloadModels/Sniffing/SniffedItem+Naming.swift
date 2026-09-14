import Foundation

public extension SniffedItem {
    /// Use the containing page's title for media, retaining an explicit attachment name when
    /// available. Manifest names remain stems until the selected output container is known.
    func downloadFileName(pageTitle: String, mimeType: String? = nil) -> String? {
        let supplied = CapturedDownload.sanitizedFileName(filename)
        switch type {
        case .page: return nil
        case .file: return supplied
        case .stream:
            return supplied ?? CapturedDownload.sanitizedFileName(pageTitle)
        case .video, .audio:
            guard let resolvedURL else { return supplied }
            let stem = supplied ?? CapturedDownload.sanitizedFileName(pageTitle)
            return FileNaming.mediaFileName(suggested: stem, url: resolvedURL, mimeType: mimeType)
        }
    }
}

public extension FileNaming {
    /// Complete a direct media name using an observed response type or a known media extension.
    /// An extensionless player endpoint does not imply MP4; leave it without an extension until
    /// the download's metadata probe supplies one. Dots in a page title are part of the title.
    static func mediaFileName(suggested: String?, url: URL, mimeType: String?) -> String {
        let name = fileName(suggested: suggested, url: url)
        if MediaSniffer.mediaExtensions.contains((name as NSString).pathExtension.lowercased()) {
            return boundedMediaName(name)
        }
        let mime = mimeType?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let extensions = [
            "video/mp4": "mp4", "video/webm": "webm", "video/quicktime": "mov",
            "video/x-matroska": "mkv", "video/x-msvideo": "avi", "video/mpeg": "mpeg",
            "video/ogg": "ogv", "video/3gpp": "3gp", "video/x-flv": "flv",
            "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/mpeg": "mp3",
            "audio/aac": "aac", "audio/flac": "flac", "audio/x-flac": "flac",
            "audio/wav": "wav", "audio/x-wav": "wav", "audio/ogg": "ogg",
            "audio/webm": "weba", "audio/opus": "opus"
        ]
        let urlExtension = url.pathExtension.lowercased()
        guard let ext = mime.flatMap({ extensions[$0] })
            ?? (MediaSniffer.mediaExtensions.contains(urlExtension) ? urlExtension : nil) else { return boundedMediaName(name) }
        return boundedMediaName("\(name).\(ext)")
    }

    private static func boundedMediaName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        let suffix = MediaSniffer.mediaExtensions.contains(ext.lowercased()) ? ".\(ext)" : ""
        var stem = suffix.isEmpty ? name : String(name.dropLast(suffix.count))
        // Filesystem limits count UTF-8 bytes. Leave space for staging and collision suffixes.
        while stem.utf8.count + suffix.utf8.count > 240 { stem.removeLast() }
        return (stem.isEmpty ? "media" : stem) + suffix
    }
}
