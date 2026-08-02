import Foundation
import DownloadModels

/// Resolves a *page* URL (a YouTube watch page, a Vimeo page, any of the ~1800 sites yt-dlp knows)
/// into the real, playable media formats behind it — the deciphered direct video/audio URLs plus the
/// HTTP headers needed to fetch them. It is a **resolver/decipher oracle, not a downloader**: the
/// engine's own segmented transfer + mux path does the downloading, so pause/resume, persistence, and
/// the sandbox story stay ours. Modelled after `HTTPClient`: a protocol with a production
/// implementation (`YtDlpExtractor`, spawning the bundled binary) and a mock for tests.
public protocol MediaExtractor: Sendable {
    /// Resolve `pageURL` into its available formats. `cookies` and `userAgent`, when supplied by
    /// the capturing browser, let the tool authenticate exactly as the page did — the difference
    /// between a real grab and a bot-check on many sites.
    func extract(pageURL: URL, cookies: ExtractionCookies?, userAgent: String?) async throws -> ExtractedMedia

    /// The tool's version string, or `nil` when no runnable extractor is bundled — used to
    /// feature-detect at launch so the UI only offers page extraction when it can actually work.
    func version() async -> String?
}

/// How browser cookies ride into a page extraction.
public enum ExtractionCookies: Sendable, Hashable {
    /// A flattened `Cookie:`-header string for the page's own host — what a single-site capture
    /// (deep link, share) carries.
    case header(String)
    /// A Netscape `cookies.txt` on disk — a whole multi-domain jar with its scoping intact (the
    /// in-app browser's store; a youtube.com grab may need accounts.google.com cookies too).
    case file(URL)
}

// MARK: - Extracted models

/// The result of resolving a page: its title and the flat list of media formats found. Purely a
/// value type — mapped into the app's existing `MediaStream`/`MediaPlan` for the quality picker.
public struct ExtractedMedia: Sendable, Hashable {
    public let title: String
    public let webpageURL: URL?
    public let extractor: String?
    public let isLive: Bool
    public let formats: [ExtractedFormat]
    /// Subtitle tracks yt-dlp reported for the page (manual `subtitles`, else `automatic_captions`),
    /// one per language — downloadable as `.srt` sidecars alongside the chosen video.
    public let subtitles: [ExtractedSubtitle]

    public init(
        title: String,
        webpageURL: URL? = nil,
        extractor: String? = nil,
        isLive: Bool = false,
        formats: [ExtractedFormat],
        subtitles: [ExtractedSubtitle] = []
    ) {
        self.title = title
        self.webpageURL = webpageURL
        self.extractor = extractor
        self.isLive = isLive
        self.formats = formats
        self.subtitles = subtitles
    }

    /// The direct-file formats our engine can actually grab (a single ranged HTTP(S) resource, not a
    /// manifest sub-protocol or DASH-segment stream).
    public var directFormats: [ExtractedFormat] { formats.filter(\.isDirectFile) }

    /// One adaptive manifest to hand back to the app's own HLS/DASH resolver when an extractor has
    /// no direct-file formats. yt-dlp often expands a master into several per-quality playlists;
    /// choosing the highest known resolution/bitrate keeps the page grab a single deterministic
    /// item. A master with no dimensions remains the fallback when it is the only manifest.
    public var preferredManifestFormat: ExtractedFormat? {
        let manifests = formats.filter { format in
            guard format.url.scheme == "http" || format.url.scheme == "https" else { return false }
            let proto = (format.proto ?? "").lowercased()
            return proto == "m3u8" || proto == "m3u8_native"
                || ["m3u8", "m3u", "mpd"].contains(format.url.pathExtension.lowercased())
        }
        return manifests.max { lhs, rhs in
            let left = (lhs.height ?? 0, lhs.width ?? 0, lhs.tbr ?? 0)
            let right = (rhs.height ?? 0, rhs.width ?? 0, rhs.tbr ?? 0)
            if left.0 != right.0 { return left.0 < right.0 }
            if left.1 != right.1 { return left.1 < right.1 }
            return left.2 < right.2
        }
    }

    /// The single header set to apply to the download. yt-dlp reports per-format headers, but for a
    /// given extraction every format shares the same `User-Agent` (and `Cookie`, when needed), and the
    /// engine applies one header set per download — so the best video/progressive format's headers are
    /// representative. Video and its paired audio always share them.
    public var downloadHeaders: [String: String] {
        let ranked = directFormats.filter { $0.isVideoOnly || $0.isProgressive }
            .sorted { ($0.height ?? 0) > ($1.height ?? 0) }
        return (ranked.first ?? directFormats.first ?? preferredManifestFormat)?.httpHeaders ?? [:]
    }
}

/// One media format from an extraction: a deciphered direct URL plus the metadata needed to label it,
/// pair it with audio, and fetch it.
public struct ExtractedFormat: Sendable, Hashable, Identifiable {
    public var id: String { formatID }
    public let formatID: String
    public let url: URL
    public let ext: String
    /// Video/audio codec ids; `nil` or `"none"` means the track is absent (yt-dlp's convention).
    public let vcodec: String?
    public let acodec: String?
    public let width: Int?
    public let height: Int?
    public let fps: Double?
    /// Total / audio bitrate in kbit/s (yt-dlp `tbr`/`abr`).
    public let tbr: Double?
    public let abr: Double?
    public let filesize: Int64?
    /// BCP-47 language of this format's audio, when yt-dlp tags it — set on dubbed/multi-audio videos,
    /// so an audio-language picker can label the alternatives. `nil` for single-language content.
    public let language: String?
    /// yt-dlp transfer protocol: `https`/`http` (a direct file), or `m3u8_native`/`http_dash_segments`
    /// (a manifest/segmented stream we don't take off this path).
    public let proto: String?
    public let httpHeaders: [String: String]

    public init(
        formatID: String, url: URL, ext: String,
        vcodec: String? = nil, acodec: String? = nil,
        width: Int? = nil, height: Int? = nil, fps: Double? = nil,
        tbr: Double? = nil, abr: Double? = nil, filesize: Int64? = nil,
        language: String? = nil,
        proto: String? = nil, httpHeaders: [String: String] = [:]
    ) {
        self.formatID = formatID; self.url = url; self.ext = ext
        self.vcodec = vcodec; self.acodec = acodec
        self.width = width; self.height = height; self.fps = fps
        self.tbr = tbr; self.abr = abr; self.filesize = filesize
        self.language = language
        self.proto = proto; self.httpHeaders = httpHeaders
    }

    private static func present(_ codec: String?) -> Bool {
        guard let codec, !codec.isEmpty, codec.lowercased() != "none" else { return false }
        return true
    }
    public var hasVideo: Bool { Self.present(vcodec) }
    public var hasAudio: Bool { Self.present(acodec) }
    public var isVideoOnly: Bool { hasVideo && !hasAudio }
    public var isAudioOnly: Bool { hasAudio && !hasVideo }
    /// Already-muxed (a single file that carries both tracks) — no separate audio to fetch.
    public var isProgressive: Bool { hasVideo && hasAudio }
    /// A single directly-downloadable HTTP(S) file (what our ranged, segmented engine grabs). Excludes
    /// `m3u8*`/`http_dash_segments` — those are handled by the manifest resolver, not this path.
    public var isDirectFile: Bool {
        switch (proto ?? "https").lowercased() {
        case "https", "http", "": return true
        default: return false
        }
    }
}

/// One subtitle track from a page extraction: a direct caption-file URL plus its language, mapped
/// into a `MediaStream` subtitle track so the picker can offer it and the engine can write a sidecar.
public struct ExtractedSubtitle: Sendable, Hashable, Identifiable {
    public var id: String { language }
    /// BCP-47 language tag (`"en"`, `"es"`, `"en-US"`).
    public let language: String
    /// A human label when yt-dlp supplies one (`name`), else `nil` (the UI falls back to the code).
    public let name: String?
    public let url: URL
    /// Caption container: `vtt`/`srt`/`ttml`/`srv3`… — we request and prefer WebVTT.
    public let ext: String
    /// Machine-generated captions (yt-dlp `automatic_captions`) rather than an authored track.
    public let isAutomatic: Bool

    public init(language: String, name: String? = nil, url: URL, ext: String, isAutomatic: Bool = false) {
        self.language = language
        self.name = name
        self.url = url
        self.ext = ext
        self.isAutomatic = isAutomatic
    }
}

// MARK: - Errors

public enum MediaExtractionError: Error, Sendable, Equatable {
    /// No runnable extractor is bundled (a checkout without `scripts/fetch-ytdlp.sh`, or a stripped build).
    case toolUnavailable
    case timedOut
    /// The tool ran but exited nonzero — carries the tail of stderr (e.g. "Video unavailable",
    /// "Sign in to confirm you're not a bot"), which the UI surfaces verbatim.
    case failed(String)
    /// The tool's output wasn't the expected JSON.
    case invalidOutput
    /// Extraction succeeded but nothing our engine can grab remained (e.g. YouTube served only
    /// SABR/ciphered streams with no direct URL). Distinct from `failed` so the UI can be honest.
    case noGrabbableFormats
}

// MARK: - Process seam

/// The bit of the world `YtDlpExtractor` can't unit-test: launching a subprocess. Injected so tests
/// feed canned output instead of spawning anything.
public protocol ProcessRunning: Sendable {
    func run(executable: URL, arguments: [String], timeout: Duration) async throws -> ProcessRunResult
}

public struct ProcessRunResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr
    }
    /// stderr decoded and trimmed to its last line(s), for user-facing error messages.
    public var stderrTail: String {
        let text = (String(bytes: stderr, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.suffix(300))
    }
}
