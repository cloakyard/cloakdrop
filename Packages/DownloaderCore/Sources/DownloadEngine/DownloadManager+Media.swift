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
    /// HLS media playlist, or a no-op for DASH / a lone media playlist.
    func resolveMediaPlan(from stream: MediaStream, variantID: String, headers: [String: String] = [:]) async throws -> MediaPlan {
        guard let variant = stream.variants.first(where: { $0.id == variantID }) else {
            throw MediaParseError.noContent
        }
        let resolved = try await MediaResolver(httpClient: httpClient).resolveVariant(variant, headers: headers)
        return stream.plan(for: resolved)
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
