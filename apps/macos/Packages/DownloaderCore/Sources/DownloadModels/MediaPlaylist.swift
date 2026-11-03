import Foundation

public struct MediaPlaylist: Sendable, Hashable {
    public static let itemLimit = 100
    public let title: String
    public let entries: [MediaPlaylistEntry]
    public let hasMore: Bool

    public init(title: String, entries: [MediaPlaylistEntry], hasMore: Bool = false) {
        self.title = title
        self.entries = Array(entries.prefix(Self.itemLimit))
        self.hasMore = hasMore || entries.count > Self.itemLimit
    }
}

public struct MediaPlaylistEntry: Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let title: String
    /// Nil for unavailable entries or unsupported URLs. Keep their position visible in the preview.
    public let pageURL: URL?

    public init(index: Int, title: String, pageURL: URL?) {
        self.index = index
        self.title = title
        self.pageURL = pageURL
    }
}

/// Persisted preferences for a queued page. Resolve only when its transfer starts, so signed URLs
/// aren't spent waiting behind earlier playlist items. An already-resolved plan remains stable on resume.
public struct MediaPageSelection: Sendable, Hashable, Codable {
    public enum Quality: String, Sendable, Hashable, Codable, CaseIterable {
        case best, hd1080, hd720, audioOnly

        public var maximumHeight: Int? {
            switch self {
            case .hd1080: return 1080
            case .hd720: return 720
            case .best, .audioOnly: return nil
            }
        }
    }

    public var quality: Quality
    public var outputFormat: MediaOutputFormat

    public init(quality: Quality = .best, outputFormat: MediaOutputFormat = .compatibleMP4) {
        self.quality = quality
        self.outputFormat = quality == .audioOnly ? .originalAudio : outputFormat
    }
}
