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
    /// The ordered video (or muxed) segments to download and concatenate.
    public var segments: [MediaSegment]
    /// Carried from the chosen variant, for the row/inspector.
    public var resolution: MediaResolution?
    public var bandwidth: Int
    /// For an adaptive rendition whose audio is a *separate* stream, the audio init segment and the
    /// ordered audio segments to fetch alongside the video and mux in — so a "video" download always
    /// has sound. Both are absent when the chosen rendition is already muxed (a plain HLS variant),
    /// is itself audio-only, or the source has no separate audio. Optional so plans persisted before
    /// this existed still decode.
    public var audioInitSegment: MediaInitSegment?
    public var audioSegments: [MediaSegment]?
    /// Subtitle tracks to fetch and write as `.srt` sidecars next to the finished file. Optional so
    /// plans persisted before subtitles existed still decode; empty/absent means none were requested.
    /// Fetched best-effort at finalize — they never gate or fail the video grab.
    public var subtitles: [MediaSubtitle]?

    public init(
        format: MediaFormat,
        initSegment: MediaInitSegment? = nil,
        segments: [MediaSegment],
        resolution: MediaResolution? = nil,
        bandwidth: Int = 0,
        audioInitSegment: MediaInitSegment? = nil,
        audioSegments: [MediaSegment]? = nil,
        subtitles: [MediaSubtitle]? = nil
    ) {
        self.format = format
        self.initSegment = initSegment
        self.segments = segments
        self.resolution = resolution
        self.bandwidth = bandwidth
        self.audioInitSegment = audioInitSegment
        self.audioSegments = audioSegments
        self.subtitles = subtitles
    }

    /// Whether this plan carries a separate audio stream to download and mux into the video.
    public var hasSeparateAudio: Bool { !(audioSegments ?? []).isEmpty }

    /// Total segments to download — video plus any separate audio — the progress denominator.
    public var totalSegments: Int { segments.count + (audioSegments?.count ?? 0) }

    /// Total media duration in seconds (sum of the video segment durations).
    public var duration: Double { segments.reduce(0) { $0 + $1.duration } }

    /// Whether any segment (video or audio) uses a scheme we can't decrypt (e.g. SAMPLE-AES). The UI
    /// uses this to refuse a grab up front rather than fail mid-transfer.
    public var hasUnsupportedEncryption: Bool {
        (segments + (audioSegments ?? [])).contains { !$0.encryption.isDecryptable }
    }

    /// The distinct key URLs across all segments (video and audio) — fetched once each and cached.
    public var keyURLs: Set<URL> {
        Set((segments + (audioSegments ?? [])).compactMap { $0.encryption.method == .aes128 ? $0.encryption.keyURL : nil })
    }

    /// A plan for a single video-only file plus a separate single audio-only file, built from direct
    /// URLs with no manifest — how an adaptive source like YouTube serves its `adaptiveFormats`. The
    /// engine downloads both and muxes them (`hasSeparateAudio` is true), so a "video" grab has
    /// sound. Each URL is one whole file rather than a timed segment, so duration is 0 (unused off
    /// the manifest path — progress is byte- and segment-count-based).
    public static func pairedFiles(video: URL, audio: URL, resolution: MediaResolution? = nil) -> MediaPlan {
        MediaPlan(
            format: .dash,
            segments: [MediaSegment(id: 0, url: video, duration: 0)],
            resolution: resolution,
            audioSegments: [MediaSegment(id: 0, url: audio, duration: 0)]
        )
    }
}

public extension MediaStream {
    /// A transfer plan for `variant`, which must already be resolved (its `segments` populated),
    /// optionally muxing in a separate `audio` track (also resolved) and writing `subtitles` sidecars.
    func plan(for variant: MediaVariant, audio: MediaTrack? = nil, subtitles: [MediaSubtitle] = []) -> MediaPlan {
        MediaPlan(
            format: format,
            initSegment: variant.initSegment,
            segments: variant.segments,
            resolution: variant.resolution,
            bandwidth: variant.bandwidth,
            audioInitSegment: audio?.initSegment,
            audioSegments: (audio?.segments).flatMap { $0.isEmpty ? nil : $0 },
            subtitles: subtitles.isEmpty ? nil : subtitles
        )
    }

    /// A plan that grabs a resolved audio `track` **on its own** (the "audio only" verb): its segments
    /// become the sole stream, so finalize's single-stream remux repackages it into a clean `.m4a`
    /// (AAC) or native audio container — losslessly, no re-encode. Optionally writes `subtitles`.
    func audioOnlyPlan(for track: MediaTrack, subtitles: [MediaSubtitle] = []) -> MediaPlan {
        MediaPlan(
            format: format,
            initSegment: track.initSegment,
            segments: track.segments,
            subtitles: subtitles.isEmpty ? nil : subtitles
        )
    }

    /// The audio track to pair with `variant` so the download has sound, or `nil` when the variant is
    /// already muxed / audio-only / the stream has no separate audio.
    func audioTrack(for variant: MediaVariant) -> MediaTrack? {
        guard variant.hasVideo, !audioTracks.isEmpty else { return nil }
        switch format {
        case .hls:
            // Only an HLS variant that references an AUDIO rendition group is video-only; a variant
            // with no group is muxed and already carries its audio.
            guard let group = variant.audioGroupID else { return nil }
            let inGroup = audioTracks.filter { $0.groupID == group }
            return inGroup.first(where: \.isDefault) ?? inGroup.first
        case .dash:
            // DASH video representations never carry audio; pair the default (else first) audio set.
            return audioTracks.first(where: \.isDefault) ?? audioTracks.first
        }
    }

    /// A plan for the highest-bandwidth *resolved* variant — the default when the user doesn't pick —
    /// paired with its audio track.
    var bestPlan: MediaPlan? {
        variants
            .filter { !$0.segments.isEmpty }
            .max { $0.bandwidth < $1.bandwidth }
            .map { plan(for: $0, audio: audioTrack(for: $0)) }
    }
}
