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
        try Self.parse(try await fetch(url: url, headers: headers), url: url)
    }

    /// Fetch a manifest and return a plan for a chosen variant — or, when `variantID` is nil, the
    /// highest-bandwidth one. Resolves the variant's media playlist first if needed (HLS).
    public func resolvePlan(url: URL, variantID: String? = nil, headers: [String: String] = [:]) async throws -> MediaPlan {
        let stream = try await fetchManifest(url: url, headers: headers)

        let chosen: MediaVariant?
        if let variantID {
            chosen = stream.variants.first { $0.id == variantID }
        } else {
            chosen = stream.variants.max { $0.bandwidth < $1.bandwidth }
        }
        guard let variant = chosen else { throw MediaParseError.noContent }

        let resolved = try await resolveVariant(variant, headers: headers)
        guard !resolved.segments.isEmpty else { throw MediaParseError.noContent }

        // Pair a separate audio track (HLS AUDIO group / DASH audio set) so the video downloads with
        // sound, resolving its media playlist too (HLS). A failed audio resolution degrades to a
        // video-only grab rather than failing the whole download.
        var audio = stream.audioTrack(for: resolved)
        if let track = audio { audio = try? await resolveAudioTrack(track, headers: headers) }
        return stream.plan(for: resolved, audio: audio)
    }

    /// Populate an audio track's segments by fetching its media playlist (HLS). Returns it unchanged
    /// when already resolved (DASH, or an inline media playlist).
    public func resolveAudioTrack(_ track: MediaTrack, headers: [String: String] = [:]) async throws -> MediaTrack {
        guard track.segments.isEmpty, let playlistURL = track.playlistURL else { return track }
        let media = try Self.parse(try await fetch(url: playlistURL, headers: headers), url: playlistURL)
        guard let resolved = media.variants.first else { throw MediaParseError.noContent }
        return MediaTrack(
            id: track.id, kind: track.kind, groupID: track.groupID, name: track.name,
            language: track.language, isDefault: track.isDefault, playlistURL: playlistURL,
            initSegment: resolved.initSegment, segments: resolved.segments
        )
    }

    /// Populate a variant's segments by fetching its media playlist (HLS multivariant case). Returns
    /// the variant unchanged when it's already resolved (DASH, or a lone media playlist).
    public func resolveVariant(_ variant: MediaVariant, headers: [String: String] = [:]) async throws -> MediaVariant {
        guard variant.segments.isEmpty, let playlistURL = variant.playlistURL else { return variant }
        let media = try Self.parse(try await fetch(url: playlistURL, headers: headers), url: playlistURL)
        guard let resolved = media.variants.first else { throw MediaParseError.noContent }
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
            segments: resolved.segments
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
    private func fetch(url: URL, headers: [String: String]) async throws -> Data {
        let (_, stream) = try await httpClient.stream(HTTPDownloadRequest(url: url, headers: headers))
        var data = Data()
        for try await chunk in stream {
            data.append(chunk)
            guard data.count <= maxManifestBytes else {
                throw MediaParseError.malformed("Manifest is larger than the \(maxManifestBytes)-byte limit.")
            }
        }
        return data
    }
}
