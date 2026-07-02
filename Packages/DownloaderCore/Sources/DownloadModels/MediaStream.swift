import Foundation

/// The adaptive-streaming format a stream was parsed from.
public enum MediaFormat: String, Sendable, Hashable, Codable {
    case hls    // HLS — .m3u8
    case dash   // MPEG-DASH — .mpd
}

/// A video resolution in pixels.
public struct MediaResolution: Sendable, Hashable, Codable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
    /// Total pixels — a format-free way to rank variants by quality.
    public var pixelCount: Int { width * height }
    /// The quality tier this resolution maps to by the streaming convention — the "p" number YouTube,
    /// IDM, and browsers show (144p, 360p, 720p, 1080p, 1440p, 2160p…). For 16:9-or-taller content
    /// (standard, 4:3, portrait/Shorts) that's the shorter side, so a 1080×1920 vertical video reads
    /// "1080p", not "1920p". For content *wider* than 16:9 (cinematic 2:1, ultrawide) the tier is
    /// binned by width, not height — a 3840×1920 (2:1) master is "2160p", exactly as YouTube labels
    /// it — so we scale the width to its 16:9-equivalent height. Reproduces yt-dlp's own ladder
    /// labels across every aspect ratio.
    public var qualityHeight: Int {
        width * 9 > height * 16                        // wider than 16:9?
            ? Int((Double(width) * 9 / 16).rounded())  // bin by width (its 16:9-equivalent height)
            : min(width, height)                       // 16:9 or taller → the shorter side
    }
}

/// A byte range within a resource (HLS `#EXT-X-BYTERANGE`, DASH `mediaRange`), stored as the
/// `length@offset` HLS uses. `end` is the inclusive last byte, matching the HTTP `Range` header.
public struct MediaByteRange: Sendable, Hashable, Codable {
    public let offset: Int64
    public let length: Int64
    public init(offset: Int64, length: Int64) {
        self.offset = offset
        self.length = length
    }
    /// Inclusive last byte offset, for a `Range: bytes=offset-end` request.
    public var end: Int64 { offset + length - 1 }
}

/// The initialization segment shared by fMP4 media segments (HLS `#EXT-X-MAP`, DASH `<Initialization>`).
/// Downloaded once and prepended to the media segments during assembly.
public struct MediaInitSegment: Sendable, Hashable, Codable {
    public let url: URL
    public let byteRange: MediaByteRange?
    public init(url: URL, byteRange: MediaByteRange? = nil) {
        self.url = url
        self.byteRange = byteRange
    }
}

/// Segment encryption (HLS `EXT-X-KEY`). AES-128 CBC is the method we can decrypt (CryptoKit);
/// others are recorded so the UI can explain why a stream can't be grabbed.
public struct MediaEncryption: Sendable, Hashable, Codable {
    public enum Method: String, Sendable, Hashable, Codable {
        case none         // METHOD=NONE
        case aes128       // METHOD=AES-128 (supported)
        case sampleAES    // METHOD=SAMPLE-AES (recorded, not decryptable here)
    }
    public let method: Method
    /// The key resource (`URI`). Absent for `METHOD=NONE`.
    public let keyURL: URL?
    /// The 16-byte initialization vector, if the playlist specifies one. When absent for AES-128,
    /// it's derived from the segment's media sequence number at decryption time (HLS spec).
    public let iv: Data?
    public init(method: Method, keyURL: URL? = nil, iv: Data? = nil) {
        self.method = method
        self.keyURL = keyURL
        self.iv = iv
    }
    /// A convenience for the common cleartext case.
    public static let none = MediaEncryption(method: .none)
    /// Whether segments under this key can actually be decrypted here.
    public var isDecryptable: Bool { method == .none || method == .aes128 }
}

/// One media segment to download — a fragment of a rendition's timeline.
public struct MediaSegment: Sendable, Hashable, Codable, Identifiable {
    /// Media sequence number: the segment's index in its playlist, used for ordering and (for
    /// AES-128 without an explicit IV) deriving the initialization vector.
    public let id: Int
    public let url: URL
    /// Segment duration in seconds (`#EXTINF` / DASH segment duration).
    public let duration: Double
    /// A sub-range of `url` this segment occupies, when several segments share one resource.
    public let byteRange: MediaByteRange?
    /// The encryption in effect for this segment (`.none` when cleartext).
    public let encryption: MediaEncryption

    public init(
        id: Int,
        url: URL,
        duration: Double,
        byteRange: MediaByteRange? = nil,
        encryption: MediaEncryption = .none
    ) {
        self.id = id
        self.url = url
        self.duration = duration
        self.byteRange = byteRange
        self.encryption = encryption
    }
}

/// One quality rendition of a stream (an HLS `EXT-X-STREAM-INF`, or a DASH video `Representation`).
///
/// In HLS a master-playlist variant only carries metadata plus a `playlistURL` — its `segments` are
/// empty until that media playlist is fetched and parsed. A DASH variant, or a lone HLS media
/// playlist, is resolved up front with its `segments` populated.
public struct MediaVariant: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    /// Peak bitrate in bits per second (HLS `BANDWIDTH` / DASH `@bandwidth`).
    public let bandwidth: Int
    public let resolution: MediaResolution?
    /// Codec identifiers, e.g. `["avc1.640028", "mp4a.40.2"]`.
    public let codecs: [String]
    public let frameRate: Double?
    /// The media playlist to fetch for this rendition's segments (HLS master variants only).
    public let playlistURL: URL?
    /// Rendition group ids this variant pairs with (HLS `AUDIO` / `SUBTITLES`), matching a track's
    /// `groupID`.
    public let audioGroupID: String?
    public let subtitleGroupID: String?
    /// The init segment shared by this rendition's fMP4 segments, if any.
    public let initSegment: MediaInitSegment?
    /// The media segments, once resolved (empty for an unresolved HLS master variant).
    public var segments: [MediaSegment]

    public init(
        id: String,
        bandwidth: Int,
        resolution: MediaResolution? = nil,
        codecs: [String] = [],
        frameRate: Double? = nil,
        playlistURL: URL? = nil,
        audioGroupID: String? = nil,
        subtitleGroupID: String? = nil,
        initSegment: MediaInitSegment? = nil,
        segments: [MediaSegment] = []
    ) {
        self.id = id
        self.bandwidth = bandwidth
        self.resolution = resolution
        self.codecs = codecs
        self.frameRate = frameRate
        self.playlistURL = playlistURL
        self.audioGroupID = audioGroupID
        self.subtitleGroupID = subtitleGroupID
        self.initSegment = initSegment
        self.segments = segments
    }

    /// Sum of segment durations (0 for an unresolved variant).
    public var duration: Double { segments.reduce(0) { $0 + $1.duration } }

    /// Codec families (RFC 6381 — the part before the first `.`) that denote a video track.
    private static let videoCodecFamilies: Set<String> = [
        "avc1", "avc2", "avc3", "avc4",   // H.264/AVC
        "hvc1", "hev1", "hvc2", "hev2",   // H.265/HEVC
        "dvh1", "dvhe", "dva1", "dvav",   // Dolby Vision
        "vp08", "vp8", "vp09", "vp9",     // VP8 / VP9
        "av01",                           // AV1
        "mp4v"                            // MPEG-4 Part 2
    ]

    /// Whether this rendition carries video. True when it declares a `resolution`, or any of its
    /// `codecs` is from a video family — some HLS masters omit `RESOLUTION` but still declare a
    /// video codec (e.g. `CODECS="avc1.4d401f,mp4a.40.2"`), so resolution alone can't be trusted.
    public var hasVideo: Bool {
        if resolution != nil { return true }
        return codecs.contains { Self.videoCodecFamilies.contains($0.prefix { $0 != "." }.lowercased()) }
    }

    /// An audio-only rendition: it declares codecs and none of them are video.
    public var isAudioOnly: Bool { !codecs.isEmpty && !hasVideo }
}

/// An alternate audio or subtitle rendition (HLS `EXT-X-MEDIA`, DASH audio/text adaptation set).
public struct MediaTrack: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case audio
        case subtitle
    }
    public let id: String
    public let kind: Kind
    /// The rendition group this track belongs to (matches a variant's `audioGroupID`/`subtitleGroupID`).
    public let groupID: String?
    public let name: String?
    /// BCP-47 language tag, e.g. `"en"`, `"es"`.
    public let language: String?
    public let isDefault: Bool
    /// The media playlist to fetch for this track's segments (HLS), when it has its own.
    public let playlistURL: URL?
    public let initSegment: MediaInitSegment?
    public var segments: [MediaSegment]

    public init(
        id: String,
        kind: Kind,
        groupID: String? = nil,
        name: String? = nil,
        language: String? = nil,
        isDefault: Bool = false,
        playlistURL: URL? = nil,
        initSegment: MediaInitSegment? = nil,
        segments: [MediaSegment] = []
    ) {
        self.id = id
        self.kind = kind
        self.groupID = groupID
        self.name = name
        self.language = language
        self.isDefault = isDefault
        self.playlistURL = playlistURL
        self.initSegment = initSegment
        self.segments = segments
    }
}

/// A fully parsed adaptive-streaming manifest: the source, its format, the quality variants, and any
/// independent audio/subtitle tracks. The single value every media capture funnels through — the
/// parsers (`HLSParser`, `DASHParser`) produce it; the engine (Phase 4b) turns a chosen variant's
/// segments into work items; assembly (4c) stitches them back together.
public struct MediaStream: Sendable, Hashable, Codable {
    public let sourceURL: URL
    public let format: MediaFormat
    public var variants: [MediaVariant]
    public var audioTracks: [MediaTrack]
    public var subtitleTracks: [MediaTrack]

    public init(
        sourceURL: URL,
        format: MediaFormat,
        variants: [MediaVariant],
        audioTracks: [MediaTrack] = [],
        subtitleTracks: [MediaTrack] = []
    ) {
        self.sourceURL = sourceURL
        self.format = format
        self.variants = variants
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
    }

    /// Whether any variant still needs its media playlist fetched (an HLS master before resolution).
    /// A DASH stream or a lone HLS media playlist is already resolved.
    public var needsVariantResolution: Bool {
        variants.contains { $0.segments.isEmpty && $0.playlistURL != nil }
    }

    /// The highest-bandwidth variant — a sensible default selection.
    public var bestVariant: MediaVariant? {
        variants.max { $0.bandwidth < $1.bandwidth }
    }

    /// Every distinct encryption method used across the resolved variants — lets the UI flag a
    /// stream that uses an unsupported scheme before the user commits to a download.
    public var encryptionMethods: Set<MediaEncryption.Method> {
        var methods: Set<MediaEncryption.Method> = []
        for variant in variants {
            for segment in variant.segments where segment.encryption.method != .none {
                methods.insert(segment.encryption.method)
            }
        }
        return methods
    }
}
