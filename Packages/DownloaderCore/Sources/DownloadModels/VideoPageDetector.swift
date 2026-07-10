import Foundation

/// A curated video site the bundled page extractor (yt-dlp) resolves well, matched by host suffix so
/// every subdomain (`www.`, `m.`, `music.`) is covered.
public struct VideoPageSite: Sendable, Hashable {
    /// Human-facing name shown in the Add-Download sheet ("YouTube video").
    public let displayName: String
    /// Registrable-domain suffixes that identify the site (`youtube.com`, `youtu.be`).
    public let hostSuffixes: [String]

    public init(displayName: String, hostSuffixes: [String]) {
        self.displayName = displayName
        self.hostSuffixes = hostSuffixes
    }
}

/// Recognizes, with no network, whether a pasted URL is a *page* worth handing to the media extractor
/// (yt-dlp) rather than downloading as a file — so the Add-Download sheet can offer to grab the video
/// instead of saving `watch.html`.
///
/// Deliberately a **curated allowlist**, not "any HTML page": a link only routes to the extractor when
/// it's a known video host, so a genuine "download this file" is never hijacked. yt-dlp supports ~1800
/// sites; this names the popular ones a user is likely to paste. Add entries here as needed.
public enum VideoPageDetector {
    public static let sites: [VideoPageSite] = [
        VideoPageSite(displayName: "YouTube", hostSuffixes: ["youtube.com", "youtu.be", "youtube-nocookie.com"]),
        VideoPageSite(displayName: "Vimeo", hostSuffixes: ["vimeo.com"]),
        VideoPageSite(displayName: "TikTok", hostSuffixes: ["tiktok.com"]),
        VideoPageSite(displayName: "Twitch", hostSuffixes: ["twitch.tv"]),
        VideoPageSite(displayName: "Dailymotion", hostSuffixes: ["dailymotion.com", "dai.ly"]),
        VideoPageSite(displayName: "X", hostSuffixes: ["twitter.com", "x.com"]),
        VideoPageSite(displayName: "Facebook", hostSuffixes: ["facebook.com", "fb.watch"]),
        VideoPageSite(displayName: "Instagram", hostSuffixes: ["instagram.com"]),
        VideoPageSite(displayName: "Reddit", hostSuffixes: ["reddit.com"]),
        VideoPageSite(displayName: "SoundCloud", hostSuffixes: ["soundcloud.com"]),
        VideoPageSite(displayName: "Bilibili", hostSuffixes: ["bilibili.com"]),
    ]

    /// The matching site if `url` is a recognized video page, else `nil`. A bare site root
    /// (`youtube.com/`) is never a video, so it's excluded — every real video carries a path.
    public static func detect(_ url: URL) -> VideoPageSite? {
        // A video page is fetched over the web; a non-http(s) scheme (ftp, file, …) is never one, and
        // the extractor only speaks http(s) — so don't route it there.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard let rawHost = url.host?.lowercased() else { return nil }
        // A video always lives at a path (`/watch`, `/<id>`), never the site root — this also stops a
        // pasted homepage from being offered as a grab.
        let path = url.path
        guard !path.isEmpty, path != "/" else { return nil }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        return sites.first { site in
            site.hostSuffixes.contains { suffix in
                // Exact host or a real subdomain (dot boundary), so `evilyoutube.com` never matches.
                host == suffix || host.hasSuffix("." + suffix)
            }
        }
    }
}
