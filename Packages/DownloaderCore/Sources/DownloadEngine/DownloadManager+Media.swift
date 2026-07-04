import Foundation
import DownloadModels

/// Media (HLS/DASH) resolution entry points on the manager — they use the manager's configured
/// `HTTPClient` (proxy, headers) via `MediaResolver`. The UI fetches the manifest once for the
/// quality picker (`resolveMediaStream`), then resolves just the chosen variant into a downloadable
/// plan (`resolveMediaPlan`), which it hands to `addMedia`.
public extension DownloadManager {
    /// Fetch and parse a manifest URL for the picker. An HLS multivariant playlist's variants come
    /// back with their metadata but no segments yet (resolved on selection); DASH is fully resolved.
    func resolveMediaStream(url: URL, headers: [String: String] = [:]) async throws -> MediaStream {
        try await MediaResolver(httpClient: httpClient).fetchManifest(url: url, headers: headers)
    }

    /// Resolve the chosen variant of an already-fetched stream into a plan — a second fetch for the
    /// HLS media playlist, or a no-op for DASH / a lone media playlist. `audioTrackID` overrides which
    /// audio (language) to pair (else the variant's default); `subtitleTrackIDs` names the subtitle
    /// tracks to fetch as sidecars (empty = none).
    func resolveMediaPlan(
        from stream: MediaStream, variantID: String, audioTrackID: String? = nil,
        subtitleTrackIDs: [String] = [], headers: [String: String] = [:]
    ) async throws -> MediaPlan {
        guard let variant = stream.variants.first(where: { $0.id == variantID }) else {
            throw MediaParseError.noContent
        }
        let resolver = MediaResolver(httpClient: httpClient)
        let resolved = try await resolver.resolveVariant(variant, headers: headers)
        // Pair the variant with the chosen (else default) separate audio track and resolve its playlist
        // too, so a chosen video quality always downloads with sound. A failed audio resolution degrades
        // to a video-only grab rather than failing the whole download.
        var audio = audioTrackID.flatMap { id in stream.audioTracks.first { $0.id == id } }
            ?? stream.audioTrack(for: resolved)
        if let track = audio { audio = try? await resolver.resolveAudioTrack(track, headers: headers) }
        let subtitles = await resolvedSubtitles(stream, ids: subtitleTrackIDs, headers: headers)
        return stream.plan(for: resolved, audio: audio, subtitles: subtitles)
    }

    /// Resolve an **audio-only** grab (the "audio only" verb): fetch the chosen (else default) audio
    /// track's segments and return a plan whose sole stream is that audio — finalize repackages it into
    /// a clean `.m4a` (AAC) or native audio container, losslessly. `subtitleTrackIDs` still apply.
    func resolveAudioOnlyPlan(
        from stream: MediaStream, trackID: String?,
        subtitleTrackIDs: [String] = [], headers: [String: String] = [:]
    ) async throws -> MediaPlan {
        let resolver = MediaResolver(httpClient: httpClient)
        let chosen = trackID.flatMap { id in stream.audioTracks.first { $0.id == id } } ?? stream.defaultAudioTrack
        guard let track = chosen else { throw MediaParseError.noContent }
        let resolved = try await resolver.resolveAudioTrack(track, headers: headers)
        guard !resolved.segments.isEmpty else { throw MediaParseError.noContent }
        let subtitles = await resolvedSubtitles(stream, ids: subtitleTrackIDs, headers: headers)
        return stream.audioOnlyPlan(for: resolved, subtitles: subtitles)
    }

    /// Resolve each requested subtitle track into a fetchable `MediaSubtitle` (best-effort — a track
    /// that fails to resolve is dropped, never failing the grab). Creates its own `MediaResolver` so it
    /// composes into any plan builder without threading one across the actor boundary.
    private func resolvedSubtitles(_ stream: MediaStream, ids: [String], headers: [String: String]) async -> [MediaSubtitle] {
        guard !ids.isEmpty else { return [] }
        let resolver = MediaResolver(httpClient: httpClient)
        var subtitles: [MediaSubtitle] = []
        for id in ids {
            guard let track = stream.subtitleTracks.first(where: { $0.id == id }) else { continue }
            let resolvedTrack = (try? await resolver.resolveSubtitleTrack(track, headers: headers)) ?? track
            if let subtitle = resolvedTrack.asSubtitle { subtitles.append(subtitle) }
        }
        return subtitles
    }

    /// A sensible output name for a media grab, whose URL is a playlist (`master.m3u8`, `manifest.mpd`)
    /// rather than the file itself. Prefer the containing path segment (often the title/id), and pick
    /// the container from the segment kind: fMP4 (has an init segment) or `.ts` → `.mp4`/`.ts`. (The
    /// remuxer may later correct this to a clean `.mp4`/`.m4a` at finalize.)
    internal static func deriveMediaFileName(from url: URL, plan: MediaPlan) -> String {
        let generic: Set<String> = ["master", "index", "playlist", "manifest", "stream", "media", ""]
        let last = url.deletingPathExtension().lastPathComponent
        let stem: String
        if !generic.contains(last.lowercased()) {
            stem = last
        } else {
            let parent = url.deletingLastPathComponent().lastPathComponent
            stem = (parent.isEmpty || parent == "/") ? (url.host() ?? "video") : parent
        }

        let ext: String
        if plan.initSegment != nil {
            ext = "mp4"
        } else if plan.segments.first?.url.pathExtension.lowercased() == "ts" {
            ext = "ts"
        } else {
            ext = "mp4"
        }
        return "\(stem).\(ext)"
    }
}
