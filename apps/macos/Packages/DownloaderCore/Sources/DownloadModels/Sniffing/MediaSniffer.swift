import Foundation

/// One downloadable thing sniffed on a web page: an adaptive-stream manifest, a media file, a plain
/// file, or the page itself (for extractor hand-off). Produced by `MediaSniffer` classification and
/// consumed by `PageMediaState` / the in-app browser's media shelf.
public struct SniffedItem: Sendable, Hashable, Identifiable {
    /// Ordered by how the shelf lists them: the page's own video first, then streams (the prize on
    /// video sites), then progressive video, audio, plain files.
    public enum ItemType: Int, Sendable, Hashable, Comparable {
        case page = 0, stream = 1, video = 2, audio = 3, file = 4
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The sniffed URL, kept as the raw string the page used (classification is string-based so the
    /// sniffer never drops a URL Foundation happens to parse differently than WebKit).
    public var url: String
    public var type: ItemType
    /// Display label: the URL's decoded filename when it has one, else the URL itself.
    public var label: String
    /// A server/`Content-Disposition`-supplied filename that should win over the URL's.
    public var filename: String?
    /// For `.page` items: hand the URL to the media extractor (yt-dlp) rather than downloading it.
    public var extract: Bool

    public var id: String { url }
    /// The URL parsed for actually downloading; `nil` only for URLs Foundation cannot represent.
    public var resolvedURL: URL? { URL(string: url) }

    public init(url: String, type: ItemType, label: String? = nil, filename: String? = nil, extract: Bool = false) {
        self.url = url
        self.type = type
        let derived = MediaSniffer.fileNameFromURL(url)
        self.label = label ?? (derived.isEmpty ? url : derived)
        self.filename = filename
        self.extract = extract
    }
}

/// The media classifier/filter behind both the in-app browser's sniffer and download takeover.
/// Pure and string-based (no I/O, no WebKit), it encodes years of accumulated real-world
/// noise/dedupe heuristics and is unit-tested directly against a large fixture corpus.
public enum MediaSniffer {
    /// The collector script the browser injects into every frame (document start, page world).
    /// It ships as a resource of this module — beside `SniffEvent`, its decoding contract — so the
    /// JS and Swift halves of the wire format can never drift apart silently.
    public static let collectorScript: String = {
        guard let url = Bundle.module.url(forResource: "MediaSniffer", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8), !source.isEmpty else {
            assertionFailure("MediaSniffer.js is missing from the DownloadModels resource bundle")
            return ""
        }
        return source
    }()
    // MARK: - Recognized types

    /// Streaming manifests the app resolves into a quality picker; self-contained media files; and
    /// plain downloadable files. Segment extensions are the chunks of an adaptive stream — never
    /// surfaced individually (the manifest is what we want).
    public static let streamExtensions: Set<String> = ["m3u8", "m3u", "mpd"]
    public static let mediaExtensions: Set<String> = [
        "mp4", "m4v", "mov", "webm", "mkv", "avi", "flv", "wmv", "mpg", "mpeg", "3gp", "ogv",
        "mp3", "m4a", "aac", "flac", "wav", "ogg", "oga", "opus", "weba"
    ]
    public static let fileExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "pkg", "iso",
        "exe", "msi", "apk", "deb", "rpm", "pdf", "epub"
    ]
    public static let segmentExtensions: Set<String> = ["ts", "m4s", "cmfv", "cmfa", "cmft", "cmfm"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "ogg", "oga", "opus", "weba"]

    /// Response MIME types that mark a plain downloadable file. Deliberately explicit —
    /// `application/octet-stream` alone is NOT here (every API blob would match); an octet-stream
    /// download still gets caught by its URL extension or its `Content-Disposition: attachment`.
    static let fileMIMETypes: Set<String> = [
        "application/zip", "application/x-zip-compressed",
        "application/x-rar-compressed", "application/vnd.rar", "application/x-7z-compressed",
        "application/x-tar", "application/gzip", "application/x-gzip", "application/x-xz",
        "application/x-bzip2",
        "application/pdf", "application/epub+zip",
        "application/x-apple-diskimage", "application/x-iso9660-image",
        "application/vnd.android.package-archive",
        "application/x-msdownload", "application/x-msdos-program", "application/x-msi",
        "application/x-debian-package", "application/x-rpm", "application/x-redhat-package-manager"
    ]

    /// URL substrings that mark analytics / telemetry / ad pings — never downloadable media.
    static let beaconHints: [String] = [
        "generate_204", "gen_204", "/qoe", "/ptracking", "/atr?", "/atr/", "/api/stats", "/log_event",
        "/csi?", "/pagead/", "doubleclick.net", "google-analytics.com", "scorecardresearch",
        "/beacon", "/collect?", "/measurement", "/interaction?"
    ]
    /// Third-party ad-network / ad-exchange / video-ad-server hosts. Media served from these is an
    /// advertisement (pre-roll, mid-roll, banner video, VAST/VMAP creative), never the page's own
    /// content — so it must never reach the shelf or a download takeover. Matched on the registrable
    /// host so every subdomain is covered (`s0.2mdn.net`, `pubads.g.doubleclick.net`). YouTube's own
    /// ad segments ride googlevideo.com (already dropped in `isNoise`); the page's real video comes via
    /// the yt-dlp page-extraction path, which skips ads itself.
    static let adHostSuffixes: [String] = [
        // Google ad stack — specific ad subdomains for the shared parents, so google.com and
        // googleapis.com themselves (e.g. Cloud Storage media) stay clear.
        "doubleclick.net", "2mdn.net", "googlesyndication.com", "googleadservices.com",
        "googletagservices.com", "adservice.google.com", "imasdk.googleapis.com",
        "amazon-adsystem.com",
        // Exchanges, SSPs & dedicated video-ad servers.
        "adnxs.com", "adsrvr.org", "adform.net", "adsafeprotected.com", "moatads.com",
        "serving-sys.com", "innovid.com", "springserve.com", "spotxchange.com", "spotx.tv",
        "teads.tv", "smartadserver.com", "pubmatic.com", "rubiconproject.com",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com", "yieldmo.com",
        "3lift.com", "casalemedia.com", "conversantmedia.com", "adcolony.com",
        "aniview.com", "flashtalking.com", "celtra.com", "sizmek.com", "freewheel.tv", "fwmrm.net",
        "stickyadstv.com", "tremorhub.com", "telaria.com", "unrulymedia.com", "openx.net",
        "contextweb.com", "sonobi.com", "gumgum.com", "sharethrough.com", "media.net",
        "zedo.com", "yieldlab.net", "improvedigital.com", "smartclip.net", "adroll.com",
        "bidswitch.net", "mgid.com", "revcontent.com", "applovin.com", "vungle.com", "inmobi.com",
        // Pop/banner networks that dominate video-piracy and adult sites — the pages where a
        // sniffer sees the most third-party "media" that is really an ad creative.
        "exoclick.com", "trafficjunky.net", "juicyads.com", "popads.net", "propellerads.com",
        "adsterra.com", "hilltopads.net", "adcash.com", "popcash.net", "tsyndicate.com"
    ]
    /// Generic UI / notification sound basenames (site-agnostic). These short, generically-named
    /// audio clips are overwhelmingly interface sounds, not content — this kills YouTube's
    /// open.mp3 / success.mp3 / failure.mp3 junk without any YouTube-specific rule.
    static let uiSoundNames: Set<String> = [
        "open", "close", "success", "failure", "error", "click", "no_input", "notification",
        "ding", "beep", "pop", "tap", "select", "hover", "start", "stop", "mute", "unmute",
        "alert", "chime", "ping", "tick", "swipe", "toggle"
    ]
    /// Media smaller than this is a ping / sound effect, not a real download.
    static let minMediaBytes: Int64 = 1024

    // MARK: - URL pieces

    /// The URL's `host[:port]`, or `""` when unparseable — mirrors JS `new URL(url).host`
    /// (which lowercases the hostname).
    public static func hostOf(_ url: String) -> String {
        guard let comps = URLComponents(string: url), let host = comps.host?.lowercased() else { return "" }
        return comps.port.map { "\(host):\($0)" } ?? host
    }

    /// The lowercase extension of the URL path's last segment, or `""`. (A leading-dot name like
    /// `.m3u8` DOES yield `m3u8` here — the Unified Streaming master case.)
    public static func extensionOf(_ url: String) -> String {
        guard let last = URLComponents(string: url)?.path.split(separator: "/").last else { return "" }
        guard let dot = last.lastIndex(of: ".") else { return "" }
        return last[last.index(after: dot)...].lowercased()
    }

    public static func audioExt(_ ext: String) -> Bool { audioExtensions.contains(ext) }

    /// The decoded filename of the URL path, or `""` when it has none / can't be decoded.
    public static func fileNameFromURL(_ url: String) -> String {
        guard let comps = URLComponents(string: url) else { return "" }
        guard let last = comps.percentEncodedPath.split(separator: "/").last else { return "" }
        return String(last).removingPercentEncoding ?? ""
    }

    /// The lowercase extension of a bare filename, or `""`. (Unlike `extensionOf`, a leading-dot
    /// name like `.m3u8` has NO extension — its stem is empty.)
    static func extOfName(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    /// `name` with its final `.ext` stripped (`fileSequence7.aac` → `fileSequence7`; no-op without one).
    static func stripLastExtension(_ name: String) -> String {
        name.replacingOccurrences(of: #"\.[^.]+$"#, with: "", options: .regularExpression)
    }

    /// The bare `type/subtype` of a MIME header value — parameters stripped, trimmed, lowercased.
    static func baseMIMEType(_ value: String?) -> String {
        let raw = value ?? ""
        let base = raw.firstIndex(of: ";").map { String(raw[..<$0]) } ?? raw
        return base.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The key a sniffed URL is *recorded* under. Signed CDN URLs rotate their query per request
    /// (`video.mp4?token=A`, then `?token=B`) — recording by full URL shows the same file twice. When
    /// the path itself names a media/file resource, key on host+path so re-tokenized repeats overwrite
    /// (keeping the freshest URL) instead of duplicating. Extensionless endpoints
    /// (`/videoplayback?id=X`) keep the full URL — there the query IS the identity.
    public static func recordKey(_ url: String) -> String {
        let ext = extensionOf(url)
        if streamExtensions.contains(ext) || mediaExtensions.contains(ext) || fileExtensions.contains(ext),
           let comps = URLComponents(string: url) {
            return hostOf(url) + comps.path
        }
        return url
    }

    // MARK: - Noise

    /// True when `host` (as returned by `hostOf`, so it may carry a `:port`) is, or is a subdomain of,
    /// a known ad-network host — matched on the registrable domain so every subdomain is covered.
    static func isAdHost(_ host: String) -> Bool {
        let h = host.split(separator: ":").first.map(String.init) ?? host
        return adHostSuffixes.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// True when a URL/response is noise we must never surface as downloadable media. `contentLength`
    /// comes from response headers when known.
    public static func isNoise(_ url: String, contentLength: Int64? = nil) -> Bool {
        let lower = url.lowercased()
        let host = hostOf(url).lowercased()
        // Raw adaptive chunk hosts — split, signed, per-range; useless as bare URLs. YouTube's
        // googlevideo traffic is handled by the dedicated page-extraction path, not the generic list.
        if host.hasSuffix("googlevideo.com") { return true }
        // Third-party ad-network media is an advertisement, never the page's own content.
        if isAdHost(host) { return true }
        if beaconHints.contains(where: { lower.contains($0) }) { return true }
        let ext = extensionOf(url)
        if segmentExtensions.contains(ext) { return true }
        // A byte-windowed fetch (Facebook/Instagram-style `bytestart=…&byteend=…`, or an explicit
        // `range=0-1023`) is one chunk of a file the player assembles — downloading the URL yields
        // a broken partial, so it must never be offered. The page-extraction path grabs the real thing.
        if lower.contains("bytestart=") && lower.contains("byteend=") { return true }
        if lower.firstMatch(of: /[?&]range=\d+-\d+/) != nil { return true }
        // Interface sound effects: a short, generically-named audio clip.
        let base = stripLastExtension(fileNameFromURL(url)).lowercased()
        if audioExt(ext) && uiSoundNames.contains(base) { return true }
        // Sub-1 KB "media" is a ping/sound, not content.
        if let contentLength, contentLength > 0, contentLength < minMediaBytes { return true }
        return false
    }

    // MARK: - Classification

    /// A media item derived from a URL alone, or `nil` if the URL isn't recognisably media/file.
    /// `contentLength` — when a caller knows it from response headers — rides into the noise gate,
    /// so a sub-1 KB response can't resurrect via the URL path.
    public static func classifyByURL(_ url: String, contentLength: Int64? = nil) -> SniffedItem? {
        if isNoise(url, contentLength: contentLength) { return nil }
        let ext = extensionOf(url)
        if ext.isEmpty { return nil }
        if streamExtensions.contains(ext) { return SniffedItem(url: url, type: .stream) }
        if mediaExtensions.contains(ext) { return SniffedItem(url: url, type: audioExt(ext) ? .audio : .video) }
        if fileExtensions.contains(ext) { return SniffedItem(url: url, type: .file) }
        return nil
    }

    /// The filename of an explicit `Content-Disposition: attachment`, or `nil` when the response
    /// isn't an attachment (absent header, or `inline`). An attachment with no usable name returns "".
    public static func attachmentFilename(_ disposition: String?) -> String? {
        let header = disposition ?? ""
        guard header.range(of: #"^\s*attachment"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        // RFC 5987 `filename*=utf-8'lang'…` (the language tag is usually empty) wins over the plain
        // quoted/bare `filename=`.
        if let match = header.firstMatch(of: /(?i)filename\*\s*=\s*(?:utf-8|iso-8859-1)'[^']*'([^;]+)/) {
            let raw = String(match.1).trimmingCharacters(in: .whitespaces)
            return raw.removingPercentEncoding ?? raw
        }
        let unescaped: (Substring) -> String = { raw in
            String(raw)
                .replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        if let match = header.firstMatch(of: /(?i)filename\s*=\s*"((?:[^"\\]|\\.)*)"/) { return unescaped(match.1) }
        if let match = header.firstMatch(of: /(?i)filename\s*=\s*([^;\r\n]+)/) { return unescaped(match.1) }
        return ""
    }

    /// A media/file item derived from response headers, for URLs without a telltale extension.
    /// `Content-Disposition: attachment` is the server saying "this is a download" — trusted even when
    /// the content-type is a generic octet-stream, and its filename beats the URL's.
    public static func classifyByContentType(
        _ url: String,
        contentType: String?,
        contentLength: Int64? = nil,
        contentDisposition: String? = nil
    ) -> SniffedItem? {
        let name = attachmentFilename(contentDisposition)
        let type = baseMIMEType(contentType)
        if let name {
            if isNoise(url, contentLength: contentLength) { return nil }
            let ext = { let byName = extOfName(name); return byName.isEmpty ? extensionOf(url) : byName }()
            var kind: SniffedItem.ItemType = .file
            if streamExtensions.contains(ext) {
                kind = .stream
            } else if mediaExtensions.contains(ext) {
                kind = audioExt(ext) ? .audio : .video
            } else if type.hasPrefix("video/") {
                kind = .video
            } else if type.hasPrefix("audio/") {
                kind = .audio
            }
            var item = SniffedItem(url: url, type: kind)
            if !name.isEmpty {
                item.filename = name
                item.label = name
            }
            return item
        }
        guard let contentType, !contentType.isEmpty else { return nil }
        if isNoise(url, contentLength: contentLength) { return nil }
        // HLS servers are split between the registered type, the legacy x- form, and the audio/
        // variants (`audio/mpegurl` predates video HLS and is still common).
        if type == "application/vnd.apple.mpegurl" || type == "application/x-mpegurl"
            || type == "audio/mpegurl" || type == "audio/x-mpegurl" || type == "application/dash+xml" {
            return SniffedItem(url: url, type: .stream)
        }
        if type.hasPrefix("video/") { return SniffedItem(url: url, type: .video) }
        if type.hasPrefix("audio/") { return SniffedItem(url: url, type: .audio) }
        if fileMIMETypes.contains(type) { return SniffedItem(url: url, type: .file) }
        return nil
    }

    /// Should a browser-initiated download of `url` be taken over by the engine? Mirrors IDM's
    /// "intercept by type" list: known file/media extensions (the attachment's filename wins over the
    /// URL) or a recognised file/media MIME. Unknown types stay with the browser — never break a
    /// download we can't positively identify.
    public static func interceptable(_ url: String, filename: String?, mime: String?) -> Bool {
        guard url.range(of: #"^https?:"#, options: [.regularExpression, .caseInsensitive]) != nil else { return false }
        if isNoise(url) { return false }
        let ext = { let byName = extOfName(filename ?? ""); return byName.isEmpty ? extensionOf(url) : byName }()
        if fileExtensions.contains(ext) || mediaExtensions.contains(ext) { return true }
        let type = baseMIMEType(mime)
        if fileMIMETypes.contains(type) { return true }
        if type.hasPrefix("video/") || type.hasPrefix("audio/") { return true }
        return false
    }

    // MARK: - Rendition collapsing

    // A single video is served as many URLs: a master playlist, one variant playlist per quality,
    // and several progressive files (per resolution/codec). Surfacing them all is the "wall of
    // streams" bug. We collapse every rendition of ONE video to a single representative by keying on
    // the video's directory with the *rendition* path segments (container role / codec / resolution)
    // stripped out — so all qualities of a video share a key, while genuinely different files never
    // merge (a URL with no rendition markers keys as nil and passes through untouched).

    /// Path segments that denote a rendition's role, not the video's identity.
    static let renditionSegments: Set<String> = [
        "pl", "vid", "hls", "dash", "manifest", "playlist", "chunklist",   // container / playlist role
        "m3u8s", "mpds",                                                   // per-container folders (Bitmovin-style)
        "avc1", "avc", "h264", "h265", "hevc", "hvc1", "av01", "vp9", "vp09", "mp4a", "aac", "opus", // codec
        "sd", "hd", "fhd", "uhd", "hi", "mid", "low", "hq", "lq"           // named qualities
    ]

    static func isRenditionSeg(_ segment: String) -> Bool {
        renditionSegments.contains(segment)
            || segment.wholeMatch(of: /\d{2,5}x\d{2,5}/) != nil     // 720x1280
            || segment.wholeMatch(of: /\d{3,4}p/) != nil            // 720p
    }

    static func pathSegments(_ url: String) -> [String] {
        guard let comps = URLComponents(string: url) else { return [] }
        return comps.path.lowercased().split(separator: "/").map(String.init)
    }

    /// A grouping key that unites all rendition variants of one video, or `nil` when the URL carries
    /// no rendition structure (so distinct files/standalone media are never collapsed together).
    public static func videoKey(_ url: String) -> String? {
        let segs = pathSegments(url)
        guard !segs.isEmpty else { return nil }
        let dirs = segs.dropLast()                                   // drop the (per-rendition) filename
        guard dirs.contains(where: isRenditionSeg) else { return nil } // no variant structure → own item
        let stable = dirs.filter { !isRenditionSeg($0) }
        return hostOf(url) + "/" + stable.joined(separator: "/")
    }

    static func resolutionArea(_ url: String) -> Int {
        guard let match = url.firstMatch(of: /(\d{2,5})x(\d{2,5})/),
              let width = Int(match.1), let height = Int(match.2) else { return 0 }
        return width * height
    }

    /// Pick the one item to show for a group of renditions: prefer a stream (the app expands it into
    /// a quality picker, covering every rendition at once); among streams prefer the master
    /// (shallowest path — a master playlist sits above its per-quality variants). With no stream,
    /// prefer the highest-resolution progressive file. Ties keep first-sighted order.
    static func pickRepresentative(_ group: [SniffedItem]) -> SniffedItem {
        let streams = group.filter { $0.type == .stream }
        let pool = streams.isEmpty ? group : streams
        return pool.enumerated().sorted { lhs, rhs in
            let lhsDepth = pathSegments(lhs.element.url).count, rhsDepth = pathSegments(rhs.element.url).count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            let lhsArea = resolutionArea(lhs.element.url), rhsArea = resolutionArea(rhs.element.url)
            if lhsArea != rhsArea { return lhsArea > rhsArea }
            return lhs.offset < rhs.offset
        }[0].element
    }

    /// Collapse rendition variants to one representative per video; pass non-rendition items through.
    static func collapseRenditions(_ items: [SniffedItem]) -> [SniffedItem] {
        enum Slot { case single(SniffedItem); case group(Int) }
        var groups: [String: Int] = [:]
        var groupItems: [[SniffedItem]] = []
        var out: [Slot] = []
        for item in items {
            guard let key = videoKey(item.url) else { out.append(.single(item)); continue }
            if let index = groups[key] {
                groupItems[index].append(item)
            } else {
                groups[key] = groupItems.count
                groupItems.append([item])
                out.append(.group(groupItems.count - 1))   // reserve position at first sight
            }
        }
        return out.map { slot in
            switch slot {
            case .single(let item): return item
            case .group(let index): return pickRepresentative(groupItems[index])
            }
        }
    }
}
