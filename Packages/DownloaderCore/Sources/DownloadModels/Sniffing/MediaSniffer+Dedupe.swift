import Foundation

// The dedupe cascade: one video on a page shows up as dozens of URLs (master playlist, per-quality
// variant playlists, progressive renditions, hundreds of segments, HLS+DASH twins, CDN mirrors).
// `dedupeAndRank` collapses all of that to one row per *thing the user would actually download*.
// Direct port of media.js — same passes, same heuristics, same test corpus.
extension MediaSniffer {
    // MARK: - Stream playlist + segment collapsing

    // A single adaptive video also shows up as (a) several sub-playlists — one HLS variant `.m3u8`
    // per quality, plus audio/subtitle renditions — that live in sibling sub-folders of the master,
    // and (b) hundreds of media *segments* (numbered chunks) that carry a normal media extension but
    // are useless individually. Neither is caught by resolution/codec rendition-keying, so they need
    // their own passes.

    static func dirKey(_ url: String) -> String {
        let segs = pathSegments(url).dropLast()   // drop filename
        return hostOf(url) + "/" + segs.joined(separator: "/")
    }

    /// Filename stems that mark a *multivariant* ("master") playlist rather than a per-quality
    /// variant — includes the empty stem (Unified Streaming serves it as `<asset>.ism/.m3u8`).
    static let multivariantStems: Set<String> = ["", "master", "index", "main", "manifest", "playlist", "all", "stream", "video"]

    static func stemOf(_ url: String) -> String { stripLastExtension(fileNameFromURL(url)).lowercased() }

    /// One stream playlist's identity facts, shared by the three collapse passes.
    private struct PlaylistMeta {
        let url: String
        let dir: String
        let depth: Int
        let stem: String
        init(_ item: SniffedItem) {
            url = item.url
            dir = dirKey(item.url)
            depth = pathSegments(item.url).count
            stem = stemOf(item.url)
        }
    }

    /// Keep only the *multivariant* playlist of each stream. A stream is a per-quality variant
    /// (drop it) when either (1) its folder is a strict descendant of another stream's folder
    /// (Apple/Mux/Bitmovin put variants in sub-folders), or (2) it sits in the SAME folder as a
    /// master-named playlist (Unified Streaming lists `.m3u8` + `<asset>-audio=…-video=….m3u8`
    /// siblings). Two unrelated masters — non-nested folders, or same-folder but neither
    /// master-named — both survive. Finally (3) an HLS+DASH twin of one asset folds to the HLS one.
    static func collapseStreamPlaylists(_ items: [SniffedItem]) -> [SniffedItem] {
        let streams = items.filter { $0.type == .stream }
        guard streams.count >= 2 else { return items }
        let meta = streams.map(PlaylistMeta.init)
        var keep = Set(streams.map(\.url))
        dropDescendantVariants(meta, keep: &keep)
        dropSameFolderVariants(meta, keep: &keep)
        foldContainerTwins(meta, keep: &keep)
        return items.filter { $0.type != .stream || keep.contains($0.url) }
    }

    /// Pass (1): a playlist whose folder is a strict descendant of another stream's folder is that
    /// stream's variant.
    private static func dropDescendantVariants(_ meta: [PlaylistMeta], keep: inout Set<String>) {
        for candidate in meta {
            for other in meta where other.url != candidate.url {
                if other.depth < candidate.depth, candidate.dir.hasPrefix(other.dir + "/") {
                    keep.remove(candidate.url)
                    break
                }
            }
        }
    }

    /// Pass (2): within one folder, a master-named sibling makes the rest variants; with no master
    /// name, a uniquely, *markedly* shorter stem is the un-decorated master beside its
    /// quality-encoding variants (Shaka `hls.m3u8` next to `playlist_v-0360p-…m3u8`). The margin is
    /// deliberately large so two similarly-named videos ("movie1"/"movie2") never collapse.
    private static func dropSameFolderVariants(_ meta: [PlaylistMeta], keep: inout Set<String>) {
        var byDir: [String: [PlaylistMeta]] = [:]
        for entry in meta where keep.contains(entry.url) { byDir[entry.dir, default: []].append(entry) }
        for group in byDir.values {
            guard group.count >= 2 else { continue }
            let multivariantCount = group.count { multivariantStems.contains($0.stem) }
            if multivariantCount > 0 && multivariantCount < group.count {
                for entry in group where !multivariantStems.contains(entry.stem) { keep.remove(entry.url) }
                continue
            }
            if multivariantCount == 0 {
                let lens = group.map { $0.stem.count }.sorted()
                let shortest = group.filter { $0.stem.count == lens[0] }
                if shortest.count == 1, lens[0] * 3 <= lens[1] || lens[1] - lens[0] >= 10 {
                    for entry in group where entry.stem.count != lens[0] { keep.remove(entry.url) }
                }
            }
        }
    }

    /// Pass (3): the same asset offered in BOTH containers from one folder — `video.m3u8` +
    /// `video.mpd` (identical stems), or a master-named pair like `master.m3u8` + `manifest.mpd`.
    /// One video, two protocols: keep the HLS one (broadest support in the app's picker).
    private static func foldContainerTwins(_ meta: [PlaylistMeta], keep: inout Set<String>) {
        var byDir: [String: [PlaylistMeta]] = [:]
        for entry in meta where keep.contains(entry.url) { byDir[entry.dir, default: []].append(entry) }
        let containerOrder = ["m3u8", "m3u", "mpd"]
        for group in byDir.values {
            guard group.count >= 2 else { continue }
            var byIdentity: [String: [PlaylistMeta]] = [:]
            for entry in group {
                let identity = multivariantStems.contains(entry.stem) ? " master" : entry.stem
                byIdentity[identity, default: []].append(entry)
            }
            for twins in byIdentity.values {
                guard twins.count >= 2 else { continue }
                guard Set(twins.map { extensionOf($0.url) }).count >= 2 else { continue }  // same container → distinct assets
                let ranked = twins.enumerated().sorted { lhs, rhs in
                    let lhsRank = containerOrder.firstIndex(of: extensionOf(lhs.element.url)) ?? -1
                    let rhsRank = containerOrder.firstIndex(of: extensionOf(rhs.element.url)) ?? -1
                    return lhsRank != rhsRank ? lhsRank < rhsRank : lhs.offset < rhs.offset
                }
                for loser in ranked.dropFirst() { keep.remove(loser.element.url) }
            }
        }
    }

    // MARK: - Segment-looking media

    /// STRONG signals that a media URL is an adaptive-stream part rather than a standalone download:
    /// an explicit segment/init/chunk word, a resolution/bitrate/codec tag, or a track-role prefix
    /// (Shaka `audio_en…`, `text_el`, `v-0360p`, `a-eng`, `s-en`). These are specific enough to trust
    /// ANYWHERE on the page (a stream's media often lives on a different CDN host/path than its
    /// manifest — e.g. DASH-IF's segments on dash.edgesuite.net).
    static func looksLikeStreamSegment(_ url: String) -> Bool {
        let name = fileNameFromURL(url).lowercased()
        let stem = stripLastExtension(name)
        // A double media extension (foo.mp4.dash, seg.264.dash, x.ts.enc): the inner extension means
        // the "file" is a wrapped stream segment, never a standalone download.
        if name.firstMatch(of: /\.(mp4|m4v|m4a|m4s|ts|264|265|h264|h265|aac|webm|ismv|isma|dash|mpd|m3u8)\.[a-z0-9]{1,6}$/) != nil {
            return true
        }
        return stem.firstMatch(of: /(^|[_\-.])(init|seg|segment|frag|fragment|chunk)([_\-.]|\d|$)/) != nil
            || stem.firstMatch(of: /\d+x\d+|\b\d{3,4}p\b|\b\d{2,5}k\b/) != nil
            || stem.firstMatch(of: /(avc1?|hevc|hvc1|h26[45]|vp0?9|av01|opus|mp4a)/) != nil
            || stem.firstMatch(of: /^(audio|video|text|subtitle|sub|cc)[_\-]/) != nil
            || stem.firstMatch(of: /(^|[_\-])[avs]-[a-z0-9]/) != nil
    }

    /// The strong signals PLUS the WEAK "name just ends in a digit" heuristic. On its own the weak
    /// part can't tell a segment (fileSequence7) from a real download (movie-2024), so callers apply
    /// it only to files sitting in a manifest's own folder — never to spare an unrelated
    /// digit-ending download.
    static func looksLikeStreamPart(_ url: String) -> Bool {
        let stem = stripLastExtension(fileNameFromURL(url)).lowercased()
        return stem.firstMatch(of: /\d$/) != nil || looksLikeStreamSegment(url)
    }

    /// When the page served a stream manifest, its bare media files (segments, per-track init/media,
    /// subtitle tracks) are never a standalone grab — the manifest is. Drop a video/audio item that is
    /// (a) in a strict SUB-folder of a manifest (segments live under the master), or (b) in the SAME
    /// folder as a manifest *and* looks like a stream part (so a plain sibling download is spared).
    /// All gated on a manifest being present, so ordinary numbered content (podcast ep3.mp3) is kept.
    static func dropStreamMedia(_ items: [SniffedItem]) -> [SniffedItem] {
        let manifestDirs = items.filter { $0.type == .stream }.map { dirKey($0.url) }
        guard !manifestDirs.isEmpty else { return items }
        func inSubfolder(_ url: String) -> Bool {
            let dir = dirKey(url)
            return manifestDirs.contains { dir.hasPrefix($0 + "/") }
        }
        func inManifestFolder(_ url: String) -> Bool { manifestDirs.contains(dirKey(url)) }
        return items.filter { item in
            guard item.type == .video || item.type == .audio else { return true }
            if inSubfolder(item.url) { return false }                            // (a) a chunk under the master's tree
            if looksLikeStreamSegment(item.url) { return false }                 // (b) a codec/bitrate/seg-named part, any folder
            return !(inManifestFolder(item.url) && looksLikeStreamPart(item.url)) // (c) a bare digit-suffix part BESIDE the master
            // A digit-ending file in an UNRELATED folder with no strong stream marker (movie-2024.mp4
            // next to some other page's stream) is a real download and is spared — the same-folder gate.
        }
    }

    // MARK: - Cross-host mirrors

    /// Generic filenames that don't uniquely identify a file — never dedupe across hosts on these.
    static let genericNames: Set<String> = [
        "video", "media", "index", "stream", "movie", "clip", "file",
        "output", "playlist", "master", "main", "default", "sample", "content", "player", "source"
    ]

    /// Collapse the same progressive file served from more than one host — a 302 to a CDN node, or an
    /// origin/mirror pair (archive.org `/serve/…` → `dnNNN.us.archive.org/…`). Keyed on an identical,
    /// *distinctive* basename (long and non-generic) so two unrelated `video.mp4` embeds never merge.
    static func dedupeSameFile(_ items: [SniffedItem]) -> [SniffedItem] {
        var seen = Set<String>()
        return items.filter { item in
            guard item.type == .video || item.type == .audio else { return true }
            let name = fileNameFromURL(item.url).lowercased()
            let stem = stripLastExtension(name)
            if stem.count < 12 || genericNames.contains(stem) { return true }   // not distinctive → keep
            return seen.insert(name).inserted
        }
    }

    // MARK: - The cascade

    /// Drop duplicate URLs, collapse rendition variants → variant playlists → stream media →
    /// same-file mirrors, then order page → streams → video → audio → file (stable within a rank).
    public static func dedupeAndRank(_ items: [SniffedItem]) -> [SniffedItem] {
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.url).inserted }
        var out = collapseRenditions(unique)
        out = collapseStreamPlaylists(out)
        out = dropStreamMedia(out)
        out = dedupeSameFile(out)
        // A sniffed stream and the "download this page's video" hand-off are the same video twice —
        // the direct stream is the better grab (no yt-dlp round-trip), so it wins.
        if out.contains(where: { $0.type == .stream }) { out.removeAll { $0.type == .page } }
        return out.enumerated()
            .sorted { $0.element.type != $1.element.type ? $0.element.type < $1.element.type : $0.offset < $1.offset }
            .map(\.element)
    }

    // MARK: - Primary player

    /// A page's media player as the collector reports it: is it a `<video>` (vs `<audio>`), and its
    /// on-screen area in px² — enough to pick the page's main player.
    public struct SniffedPlayer: Sendable, Hashable, Codable {
        public var video: Bool
        public var area: Double
        public init(video: Bool, area: Double) {
            self.video = video
            self.area = area
        }
    }

    /// Pick the "primary" media player: the largest visible `<video>`, or — only when the page has
    /// none — the largest `<audio>`. The page-global affordances (sniffed streams and the yt-dlp
    /// page-extraction fallback) attach to just this one player, so an adaptive site like YouTube —
    /// whose watch page carries several `<video>` elements (main player, hover previews, the
    /// miniplayer), each a blob/MediaSource resolving to the same page URL — shows ONE download
    /// affordance instead of a duplicate per element. Returns -1 for an empty list.
    public static func primaryPlayerIndex(_ players: [SniffedPlayer]) -> Int {
        var best = -1
        var bestScore = -1.0
        for (index, player) in players.enumerated() {
            let score = (player.video ? 1e12 : 0) + (player.area > 0 ? player.area : 0)
            if score > bestScore {
                bestScore = score
                best = index
            }
        }
        return best
    }
}
