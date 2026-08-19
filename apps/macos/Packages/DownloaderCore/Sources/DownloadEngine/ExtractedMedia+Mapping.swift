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
        let subtitles = parseSubtitles(manual: root["subtitles"], automatic: root["automatic_captions"])
        return ExtractedMedia(
            title: sanitizeTitle(title), webpageURL: webpage,
            extractor: extractor, isLive: isLive, formats: formats, subtitles: subtitles
        )
    }

    /// Caption formats we can convert to a `.srt` sidecar (`SubtitleConverter`), best-first. JSON /
    /// `srv*` variants yt-dlp also lists aren't convertible, so a language offering only those is skipped.
    private static let convertibleSubtitleExts = ["vtt", "webvtt", "srt", "ttml", "dfxp"]

    /// Base languages we keep from `automatic_captions` — machine captions span ~190 languages, so we
    /// bound the picker to the common ones (manual/authored subtitles are always kept, never capped).
    private static let commonAutoLanguages: Set<String> = [
        "en", "es", "fr", "de", "pt", "it", "nl", "ru", "pl", "tr",
        "ja", "ko", "zh", "hi", "ar", "id", "vi", "th", "uk", "sv"
    ]

    /// Build subtitle tracks from yt-dlp's `subtitles` (authored) and `automatic_captions` maps: one
    /// entry per language, preferring a convertible format, authored over automatic, and bounding the
    /// automatic set to common languages so a 190-language caption list can't swamp the picker.
    private static func parseSubtitles(manual: Any?, automatic: Any?) -> [ExtractedSubtitle] {
        func pick(_ value: Any?, isAutomatic: Bool) -> [ExtractedSubtitle] {
            guard let dict = value as? [String: Any] else { return [] }
            var out: [ExtractedSubtitle] = []
            for (language, entries) in dict {
                guard let list = entries as? [[String: Any]] else { continue }
                let convertible = list.filter { convertibleSubtitleExts.contains((jsonString($0["ext"]) ?? "").lowercased()) }
                let ranked = convertible.sorted {
                    (convertibleSubtitleExts.firstIndex(of: (jsonString($0["ext"]) ?? "").lowercased()) ?? 99)
                        < (convertibleSubtitleExts.firstIndex(of: (jsonString($1["ext"]) ?? "").lowercased()) ?? 99)
                }
                guard let best = ranked.first, let url = jsonString(best["url"]).flatMap({ URL(string: $0) }) else { continue }
                out.append(ExtractedSubtitle(
                    language: language, name: jsonString(best["name"]),
                    url: url, ext: (jsonString(best["ext"]) ?? "vtt").lowercased(), isAutomatic: isAutomatic
                ))
            }
            return out
        }
        let authored = pick(manual, isAutomatic: false)
        let authoredLanguages = Set(authored.map(\.language))
        let auto = pick(automatic, isAutomatic: true).filter {
            !authoredLanguages.contains($0.language)
                && commonAutoLanguages.contains(String($0.language.prefix(while: { $0 != "-" })).lowercased())
        }
        // Authored first, then automatic — both alphabetized within, for a stable picker order.
        return authored.sorted { $0.language < $1.language } + auto.sorted { $0.language < $1.language }
    }

    private static func parseFormat(_ raw: [String: Any]) -> ExtractedFormat? {
        guard let urlString = jsonString(raw["url"]), let url = URL(string: urlString) else { return nil }
        let ext = jsonString(raw["ext"]) ?? (url.pathExtension.isEmpty ? "bin" : url.pathExtension)
        let formatID = jsonString(raw["format_id"]) ?? jsonString(raw["format"]) ?? url.lastPathComponent
        let proto = jsonString(raw["protocol"])
        let width = jsonInt(raw["width"])
        let height = jsonInt(raw["height"])
        var vcodec = jsonString(raw["vcodec"])
        var acodec = jsonString(raw["acodec"])

        // Several extractors (Vimeo, Flickr, Imgur, LinkedIn, Snapchat, TED, …) know that a direct
        // MP4/WebM is a video but omit both codec fields. Treat a direct HTTP(S) URL whose declared
        // container is unambiguously video as an opaque progressive file: the engine downloads it
        // unchanged, so it does not need the actual codec names. A resolution is intentionally not
        // required — some single-file extractors report neither dimensions nor codecs. Never infer
        // this for manifests or audio/image/document extensions; those need their own evidence.
        let directProtocols: Set<String> = ["", "http", "https"]
        let muxedVideoExtensions: Set<String> = [
            "mp4", "m4v", "mov", "webm", "mkv", "avi", "flv", "mpeg", "mpg", "3gp", "ogv"
        ]
        if vcodec == nil, acodec == nil,
           directProtocols.contains((proto ?? "").lowercased()),
           muxedVideoExtensions.contains(ext.lowercased()) {
            vcodec = "unknown"
            acodec = "unknown"
        }
        return ExtractedFormat(
            formatID: formatID, url: url, ext: ext,
            vcodec: vcodec, acodec: acodec,
            width: width, height: height, fps: jsonDouble(raw["fps"]),
            tbr: jsonDouble(raw["tbr"]), abr: jsonDouble(raw["abr"]),
            filesize: jsonInt64(raw["filesize"]) ?? jsonInt64(raw["filesize_approx"]),
            language: jsonString(raw["language"]),
            proto: proto, httpHeaders: jsonHeaders(raw["http_headers"])
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
    /// further network. Returns `nil` when nothing direct is grabbable or a complete adaptive stream
    /// should be resolved instead (e.g. only SABR/ciphered streams, or unpaired direct video).
    func toMediaStream(pageURL: URL) -> MediaStream? {
        let direct = directFormats
        let audioOnly = direct.filter(\.isAudioOnly)

        // Some extractors advertise direct MP4 renditions that contain video only, with no separate
        // audio resource to pair, alongside complete HLS renditions. Building direct tiers here would
        // produce a silent file (and those secondary direct URLs are often less reliable than the
        // authored player stream). Returning nil hands the complete manifest to CloakDrop's own HLS
        // resolver in `grabFromPage`, preserving audio and the normal segmented-media path.
        let hasUnpairedDirectVideo = direct.contains(where: \.isVideoOnly)
            && !direct.contains(where: \.isProgressive)
            && audioOnly.isEmpty
        if hasUnpairedDirectVideo, preferredManifestFormat?.isProgressive == true { return nil }

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
        let audioTracks = audioTrackList(ordered: ordered, audioOnly: audioOnly)
        return MediaStream(
            sourceURL: pageURL, format: .dash, variants: variants,
            audioTracks: audioTracks, subtitleTracks: subtitleTrackList
        )
    }

    /// The audio tracks to offer. When any audio format is language-tagged (a dubbed/multi-audio
    /// video), expose **one track per language** — the best bitrate of each — so an audio-language
    /// picker can choose among them. Otherwise (ordinary single-language content) expose just the
    /// audio each video tier pairs with, deduped by format id, so the picker isn't cluttered with
    /// container variants (m4a vs. webm) that aren't real language choices.
    private func audioTrackList(ordered: [Tier], audioOnly: [ExtractedFormat]) -> [MediaTrack] {
        func track(_ format: ExtractedFormat, isDefault: Bool) -> MediaTrack {
            MediaTrack(
                id: format.formatID, kind: .audio, groupID: format.formatID,
                name: format.ext.uppercased(), language: format.language, isDefault: isDefault,
                segments: [MediaSegment(id: 0, url: format.url, duration: 0)]
            )
        }

        if audioOnly.contains(where: { $0.language != nil }) {
            // Dubbed: best bitrate per language. The video's paired audio (the top tier's) is default.
            var byLanguage: [String: ExtractedFormat] = [:]
            for format in audioOnly {
                let key = format.language ?? "und"
                if let existing = byLanguage[key], (existing.abr ?? existing.tbr ?? 0) >= (format.abr ?? format.tbr ?? 0) { continue }
                byLanguage[key] = format
            }
            let defaultID = ordered.first?.audio?.formatID
            return byLanguage.values
                .sorted { ($0.language ?? "") < ($1.language ?? "") }
                .map { track($0, isDefault: $0.formatID == defaultID) }
        }

        // Single-language: the distinct audio each tier references (deduped by format id).
        var tracks: [MediaTrack] = []
        var seen = Set<String>()
        for tier in ordered {
            guard let audio = tier.audio, seen.insert(audio.formatID).inserted else { continue }
            tracks.append(track(audio, isDefault: tracks.isEmpty))
        }
        return tracks
    }

    /// The extraction's subtitles as resolved `MediaTrack`s (each a single direct caption URL, so no
    /// further fetch is needed to plan). Automatic captions are tagged `(auto)` in their label.
    private var subtitleTrackList: [MediaTrack] {
        subtitles.map { subtitle in
            let label = subtitle.name ?? subtitle.language
            return MediaTrack(
                id: subtitle.language,
                kind: .subtitle,
                name: subtitle.isAutomatic ? "\(label) (auto)" : label,
                language: subtitle.language,
                playlistURL: subtitle.url,
                segments: [MediaSegment(id: 0, url: subtitle.url, duration: 0)]
            )
        }
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
