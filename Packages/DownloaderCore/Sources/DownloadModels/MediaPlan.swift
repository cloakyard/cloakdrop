import Foundation

/// The concrete, resolved plan for grabbing one chosen rendition of a media stream: the ordered
/// segments to download (each with its own encryption), the shared fMP4 init segment, and a little
/// metadata for display.
///
/// Built from a `MediaStream` + a chosen, resolved `MediaVariant`, then attached to a `Download` so
/// the engine transfers it segment-by-segment (Phase 4b) and assembles it (4c). Resolution — i.e.
/// fetching an HLS variant's media playlist so its `segments` are populated — happens before the
/// plan is made (see `MediaResolver`).
public struct MediaPlan: Sendable, Hashable, Codable {
    public var format: MediaFormat
    public var initSegment: MediaInitSegment?
    /// The ordered segments to download and concatenate.
    public var segments: [MediaSegment]
    /// Carried from the chosen variant, for the row/inspector.
    public var resolution: MediaResolution?
    public var bandwidth: Int

    public init(
        format: MediaFormat,
        initSegment: MediaInitSegment? = nil,
        segments: [MediaSegment],
        resolution: MediaResolution? = nil,
        bandwidth: Int = 0
    ) {
        self.format = format
        self.initSegment = initSegment
        self.segments = segments
        self.resolution = resolution
        self.bandwidth = bandwidth
    }

    public var totalSegments: Int { segments.count }

    /// Total media duration in seconds (sum of segment durations).
    public var duration: Double { segments.reduce(0) { $0 + $1.duration } }

    /// Whether any segment is encrypted with a scheme we can't decrypt (e.g. SAMPLE-AES). The UI
    /// uses this to refuse a grab up front rather than fail mid-transfer.
    public var hasUnsupportedEncryption: Bool { segments.contains { !$0.encryption.isDecryptable } }

    /// The distinct key URLs across the segments — the transfer fetches each once and caches it.
    public var keyURLs: Set<URL> {
        Set(segments.compactMap { $0.encryption.method == .aes128 ? $0.encryption.keyURL : nil })
    }
}

public extension MediaStream {
    /// A transfer plan for `variant`, which must already be resolved (its `segments` populated).
    func plan(for variant: MediaVariant) -> MediaPlan {
        MediaPlan(
            format: format,
            initSegment: variant.initSegment,
            segments: variant.segments,
            resolution: variant.resolution,
            bandwidth: variant.bandwidth
        )
    }

    /// A plan for the highest-bandwidth *resolved* variant — the default when the user doesn't pick.
    var bestPlan: MediaPlan? {
        variants
            .filter { !$0.segments.isEmpty }
            .max { $0.bandwidth < $1.bandwidth }
            .map { plan(for: $0) }
    }
}
