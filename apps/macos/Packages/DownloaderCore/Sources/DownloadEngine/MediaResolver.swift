import Foundation
import DownloadModels

/// Turns a manifest URL into a ready-to-download `MediaPlan`, using the `HTTPClient` to fetch the
/// playlist(s) and the `HLSParser`/`DASHParser` to parse them.
///
/// HLS is two-level: fetching a multivariant playlist yields variants whose segments aren't known
/// until each one's media playlist is fetched — so `resolvePlan` fetches the chosen variant's
/// playlist as a second step. DASH is single-file, so its segments come straight from the `.mpd`.
///
/// Behind the `HTTPClient` protocol like the rest of the engine, so it's tested with `MockHTTPClient`
/// against fixture playlists — no network.
public struct MediaResolver {
    private let httpClient: any HTTPClient
    private let maxManifestBytes: Int

    /// A manifest is small text — KB to a low number of MB even for long VOD — so a generous
    /// ceiling keeps a broken or hostile server from streaming an unbounded body into memory.
    public init(httpClient: any HTTPClient, maxManifestBytes: Int = 16 * 1024 * 1024) {
        self.httpClient = httpClient
        self.maxManifestBytes = maxManifestBytes
    }

    /// Fetch and parse a manifest URL. An HLS multivariant playlist comes back with its variants
    /// *unresolved* (segments empty, `playlistURL` set); DASH comes back fully resolved.
    public func fetchManifest(url: URL, headers: [String: String] = [:]) async throws -> MediaStream {
        let (data, finalURL) = try await fetch(url: url, headers: headers)
        return try Self.parse(data, url: finalURL)
    }

    /// Fetch a manifest and return a plan for a chosen variant — or, when `variantID` is nil, the
    /// highest-bandwidth one. Resolves the variant's media playlist first if needed (HLS).
    public func resolvePlan(url: URL, variantID: String? = nil, headers: [String: String] = [:]) async throws -> MediaPlan {
        let stream = try await fetchManifest(url: url, headers: headers)

        let chosen: MediaVariant?
        if let variantID {
            chosen = stream.variants.first { $0.id == variantID }
        } else {
            chosen = stream.bestVariant
        }
        guard let variant = chosen else { throw MediaParseError.noContent }

        let resolved = try await resolveVariant(variant, headers: headers)
        guard !resolved.segments.isEmpty else { throw MediaParseError.noContent }

        // Pair a separate audio track (HLS AUDIO group / DASH audio set) so the video downloads with
        // sound, resolving its media playlist too (HLS). A failed separate audio request must fail
        // preparation: silently dropping it would publish a successful-looking but silent video.
        var audio = stream.audioTrack(for: resolved)
        if let track = audio { audio = try await resolveAudioTrack(track, headers: headers) }
        return stream.plan(for: resolved, audio: audio)
    }

    /// Populate an audio track's segments by fetching its media playlist (HLS). Returns it unchanged
    /// when already resolved (DASH, or an inline media playlist).
    public func resolveAudioTrack(_ track: MediaTrack, headers: [String: String] = [:]) async throws -> MediaTrack {
        guard track.segments.isEmpty, let playlistURL = track.playlistURL else { return track }
        let media = try await fetchManifest(url: playlistURL, headers: headers)
        guard let resolved = media.variants.first, !resolved.segments.isEmpty else { throw MediaParseError.noContent }
        return MediaTrack(
            id: track.id, kind: track.kind, groupID: track.groupID, name: track.name,
            language: track.language, isDefault: track.isDefault, playlistURL: playlistURL,
            initSegment: resolved.initSegment, segments: resolved.segments
        )
    }

    /// Subtitle URIs a subtitle track's `URI` may point at directly (a whole caption file), rather than
    /// at a media playlist listing WebVTT segments.
    private static let directSubtitleExtensions: Set<String> = ["vtt", "webvtt", "srt", "ttml", "xml", "dfxp"]

    /// Populate a subtitle track's segments so the engine can fetch its text. HLS points the `URI`
    /// either at a single caption file (`.vtt`/`.srt`, the common case) — which is its own lone
    /// "segment" — or at a media playlist listing WebVTT segments; DASH text sets arrive already
    /// segmented. Returns the track unchanged when there's nothing to resolve.
    public func resolveSubtitleTrack(_ track: MediaTrack, headers: [String: String] = [:]) async throws -> MediaTrack {
        guard track.segments.isEmpty, let url = track.playlistURL else { return track }
        if Self.directSubtitleExtensions.contains(url.pathExtension.lowercased()) {
            return track.withSegments([MediaSegment(id: 0, url: url, duration: 0)], initSegment: nil)
        }
        let media = try await fetchManifest(url: url, headers: headers)
        guard let resolved = media.variants.first else { throw MediaParseError.noContent }
        return track.withSegments(resolved.segments, initSegment: resolved.initSegment)
    }

    /// Populate a variant's segments by fetching its media playlist (HLS multivariant case). Returns
    /// the variant unchanged when it's already resolved (DASH, or a lone media playlist).
    public func resolveVariant(_ variant: MediaVariant, headers: [String: String] = [:]) async throws -> MediaVariant {
        guard variant.segments.isEmpty, let playlistURL = variant.playlistURL else { return variant }
        let media = try await fetchManifest(url: playlistURL, headers: headers)
        guard let resolved = media.variants.first, !resolved.segments.isEmpty else { throw MediaParseError.noContent }
        // Keep the multivariant metadata (bandwidth/resolution/codecs), take the segments + init.
        return MediaVariant(
            id: variant.id,
            bandwidth: variant.bandwidth,
            resolution: variant.resolution,
            codecs: variant.codecs,
            frameRate: variant.frameRate,
            playlistURL: variant.playlistURL,
            audioGroupID: variant.audioGroupID,
            subtitleGroupID: variant.subtitleGroupID,
            initSegment: resolved.initSegment,
            segments: resolved.segments,
            videoTrackPresent: variant.videoTrackPresent
        )
    }

    /// Pick the parser by content (an HLS playlist starts with `#EXTM3U`; a DASH manifest is XML with
    /// an `<MPD>` root), falling back to the URL extension.
    static func parse(_ data: Data, url: URL) throws -> MediaStream {
        let text = String(bytes: data, encoding: .utf8) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#EXTM3U") { return try HLSParser.parse(text, baseURL: url) }
        if trimmed.hasPrefix("<"), trimmed.contains("<MPD") { return try DASHParser.parse(data, baseURL: url) }
        if url.pathExtension.lowercased() == "mpd" { return try DASHParser.parse(data, baseURL: url) }
        return try HLSParser.parse(text, baseURL: url)
    }

    /// Fetch a small resource (a playlist) fully into memory, bounded by `maxManifestBytes` so a
    /// runaway response fails cleanly instead of exhausting memory.
    private func fetch(url: URL, headers: [String: String]) async throws -> (Data, URL) {
        let (head, stream) = try await httpClient.stream(HTTPDownloadRequest(url: url, headers: headers))
        guard head.isSuccess else { throw DownloadError.httpStatus(code: head.statusCode) }
        var data = Data()
        for try await chunk in stream {
            try Task.checkCancellation()
            guard chunk.count <= maxManifestBytes - data.count else {
                throw MediaParseError.malformed("Manifest is larger than the \(maxManifestBytes)-byte limit.")
            }
            data.append(chunk)
        }
        // Signed playback endpoints commonly redirect into another CDN directory. Relative
        // playlists, segments, keys and subtitles all belong to the final response URL.
        return (data, head.finalURL ?? url)
    }
}
