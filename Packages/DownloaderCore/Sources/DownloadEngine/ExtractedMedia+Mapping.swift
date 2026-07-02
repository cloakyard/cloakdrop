import Foundation
import DownloadModels

// Parsing yt-dlp's `-J` (dump-single-json) output into `ExtractedMedia`, and mapping that onto the
// app's existing `MediaStream`/`MediaPlan` so the quality picker and the segmented downloader work
// unchanged. Kept off the process/IO path so it's unit-testable against canned JSON.

// MARK: - Lenient JSON accessors
// yt-dlp's schema is stable for the fields we read, but numbers arrive as Int or Double (and, rarely,
// as strings), and any field can be absent. These never throw — a bad/missing field yields nil — so a
// single upstream quirk can't fail the whole extraction (this is the fragile site-scraping boundary).

private func jsonString(_ value: Any?) -> String? {
    if let string = value as? String { return string.isEmpty ? nil : string }
    return nil
}

private func jsonInt(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(string) }
    return nil
}

private func jsonInt64(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber { return number.int64Value }
    if let string = value as? String { return Int64(string) }
    return nil
}

private func jsonDouble(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
}

private func jsonHeaders(_ value: Any?) -> [String: String] {
    (value as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
}

// MARK: - Parse

public extension ExtractedMedia {
    /// Parse yt-dlp `-J` output. Throws `.invalidOutput` when it isn't the expected JSON object.
    static func parse(json data: Data) throws -> ExtractedMedia {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MediaExtractionError.invalidOutput
        }
        let title = jsonString(root["title"]) ?? jsonString(root["id"]) ?? "video"
        let webpage = jsonString(root["webpage_url"]).flatMap { URL(string: $0) }
        let extractor = jsonString(root["extractor_key"]) ?? jsonString(root["extractor"])
        let isLive = (root["is_live"] as? Bool) ?? false

        var rawFormats = root["formats"] as? [[String: Any]] ?? []
        // A few single-file extractions carry no `formats` array — the root object *is* the format.
        if rawFormats.isEmpty, jsonString(root["url"]) != nil { rawFormats = [root] }

        let formats = rawFormats.compactMap(parseFormat)
        return ExtractedMedia(
            title: sanitizeTitle(title), webpageURL: webpage,
            extractor: extractor, isLive: isLive, formats: formats
        )
    }

    private static func parseFormat(_ raw: [String: Any]) -> ExtractedFormat? {
        guard let urlString = jsonString(raw["url"]), let url = URL(string: urlString) else { return nil }
        let ext = jsonString(raw["ext"]) ?? (url.pathExtension.isEmpty ? "bin" : url.pathExtension)
        let formatID = jsonString(raw["format_id"]) ?? jsonString(raw["format"]) ?? url.lastPathComponent
        return ExtractedFormat(
            formatID: formatID, url: url, ext: ext,
            vcodec: jsonString(raw["vcodec"]), acodec: jsonString(raw["acodec"]),
            width: jsonInt(raw["width"]), height: jsonInt(raw["height"]), fps: jsonDouble(raw["fps"]),
            tbr: jsonDouble(raw["tbr"]), abr: jsonDouble(raw["abr"]),
            filesize: jsonInt64(raw["filesize"]) ?? jsonInt64(raw["filesize_approx"]),
            proto: jsonString(raw["protocol"]), httpHeaders: jsonHeaders(raw["http_headers"])
        )
    }

    /// A filesystem-safe title (drops path separators / reserved characters, collapses whitespace,
    /// caps length) — a good default download name.
    static func sanitizeTitle(_ raw: String) -> String {
        let stripped = raw.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t"))
            .joined(separator: "_")
        let collapsed = stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let capped = String(collapsed.prefix(120))
        return capped.isEmpty ? "video" : capped
    }
}

// MARK: - Map to the app's media model

public extension ExtractedMedia {
    /// Build a `MediaStream` whose variants are the distinct resolution tiers (one per height, the
    /// cheapest-to-assemble codec kept), each paired with its container-matched audio via
    /// `audioGroupID`. Every variant is *already resolved* (its single direct-URL segment is set, no
    /// `playlistURL`), so `MediaStream.plan(for:audio:)` produces a paired video+audio plan with no
    /// further network. Returns `nil` when nothing grabbable remains (e.g. only SABR/ciphered streams).
    func toMediaStream(pageURL: URL) -> MediaStream? {
        let direct = directFormats
        let audioOnly = direct.filter(\.isAudioOnly)
        var tiers: [Int: Tier] = [:]

        for format in direct where format.isProgressive {
            merge(&tiers, candidate: Tier(video: format, audio: nil, rank: 3, height: format.height ?? 0))
        }
        for format in direct where format.isVideoOnly && format.height != nil {
            let audio = Self.bestAudio(forVideoExt: format.ext, from: audioOnly)
            let rank = Self.containerFamily(of: format.ext) == "mp4" ? 2 : 1   // mp4→AVFoundation, webm→ffmpeg
            merge(&tiers, candidate: Tier(video: format, audio: audio, rank: rank, height: format.height!))
        }
        guard !tiers.isEmpty else { return nil }

        let ordered = tiers.values.sorted { $0.height > $1.height }
        let variants = ordered.map(makeVariant)
        // The distinct audio tracks the variants reference (deduped by format id).
        var audioTracks: [MediaTrack] = []
        var seenAudio = Set<String>()
        for tier in ordered {
            guard let audio = tier.audio, seenAudio.insert(audio.formatID).inserted else { continue }
            audioTracks.append(MediaTrack(
                id: audio.formatID, kind: .audio, groupID: audio.formatID,
                name: audio.ext.uppercased(), isDefault: audioTracks.isEmpty,
                segments: [MediaSegment(id: 0, url: audio.url, duration: 0)]
            ))
        }
        return MediaStream(sourceURL: pageURL, format: .dash, variants: variants, audioTracks: audioTracks)
    }

    /// A download filename for the tier whose video format id is `id`: the (already-sanitized) title
    /// plus that format's container extension. The remuxer corrects the extension at finalize if the
    /// mux settles on a different container (e.g. `.mkv` for VP9/Opus).
    func downloadName(forFormatID id: String) -> String {
        let ext = formats.first { $0.formatID == id }?.ext ?? "mp4"
        return "\(title).\(ext)"
    }

    private struct Tier { let video: ExtractedFormat; let audio: ExtractedFormat?; let rank: Int; let height: Int }

    /// Keep one tier per height: the higher assembly rank wins (progressive > mp4 > webm); ties break
    /// on total bitrate, so the sharper encode of a given resolution survives.
    private func merge(_ tiers: inout [Int: Tier], candidate: Tier) {
        guard let existing = tiers[candidate.height] else { tiers[candidate.height] = candidate; return }
        if candidate.rank > existing.rank { tiers[candidate.height] = candidate; return }
        if candidate.rank == existing.rank,
           (candidate.video.tbr ?? 0) > (existing.video.tbr ?? 0) { tiers[candidate.height] = candidate }
    }

    private func makeVariant(_ tier: Tier) -> MediaVariant {
        let format = tier.video
        let resolution = (format.width).flatMap { width in (format.height).map { MediaResolution(width: width, height: $0) } }
        let bandwidth = format.tbr.map { Int($0 * 1000) } ?? (tier.height * 2000)
        let codecs = [format.vcodec, tier.audio?.acodec ?? format.acodec]
            .compactMap { $0 }.filter { $0.lowercased() != "none" }
        return MediaVariant(
            id: format.formatID, bandwidth: bandwidth, resolution: resolution,
            codecs: codecs, frameRate: format.fps,
            audioGroupID: tier.audio?.formatID,          // nil for progressive (already has sound)
            segments: [MediaSegment(id: 0, url: format.url, duration: 0)]
        )
    }

    /// The best audio to pair with a video of `videoExt`: highest bitrate in the same container family
    /// (so the mux is a stream-copy — AAC into mp4, Opus into webm), else the best audio overall.
    static func bestAudio(forVideoExt videoExt: String, from audios: [ExtractedFormat]) -> ExtractedFormat? {
        guard !audios.isEmpty else { return nil }
        let family = containerFamily(of: videoExt)
        let sameFamily = audios.filter { containerFamily(of: $0.ext) == family }
        let pool = sameFamily.isEmpty ? audios : sameFamily
        return pool.max { ($0.abr ?? $0.tbr ?? 0) < ($1.abr ?? $1.tbr ?? 0) }
    }

    /// Group a container extension into the family that muxes together without re-encoding.
    static func containerFamily(of ext: String) -> String {
        switch ext.lowercased() {
        case "mp4", "m4v", "mov", "m4a", "aac", "mp3", "mp4a": return "mp4"
        case "webm", "mkv", "opus", "ogg", "oga", "weba": return "webm"
        default: return ext.lowercased()
        }
    }
}
