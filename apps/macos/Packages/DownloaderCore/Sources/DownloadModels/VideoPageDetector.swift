import Foundation

/// A curated video site the bundled page extractor (yt-dlp) resolves well, matched by host suffix so
/// every subdomain (`www.`, `m.`, `music.`) is covered.
public struct VideoPageSite: Sendable, Hashable {
    /// Human-facing name shown in the Add-Download sheet ("YouTube video").
    public let displayName: String
    /// Registrable-domain suffixes that identify the site (`youtube.com`, `youtu.be`).
    public let hostSuffixes: [String]
    /// A social post route may contain only text/images. Browser callers wait for actual player or
    /// media activity before treating this URL shape alone as a grabbable page.
    public let requiresObservedMedia: Bool
    /// Prefer one clean URL observed in the page's primary player when available. Pasted URLs still
    /// route through the extractor, and the browser falls back to extraction when it sees no URL.
    public let prefersObservedMedia: Bool

    public init(
        displayName: String, hostSuffixes: [String],
        requiresObservedMedia: Bool = false, prefersObservedMedia: Bool = false
    ) {
        self.displayName = displayName
        self.hostSuffixes = hostSuffixes
        self.requiresObservedMedia = requiresObservedMedia
        self.prefersObservedMedia = prefersObservedMedia
    }
}

/// Recognizes, with no network, whether a pasted URL is a *page* worth handing to the media extractor
/// (yt-dlp) rather than downloading as a file — so the Add-Download sheet can offer to grab the video
/// instead of saving `watch.html`.
///
/// Deliberately a **curated allowlist**, not "any HTML page": a link only routes to the extractor when
/// it's a known video host, so a genuine "download this file" is never hijacked. yt-dlp supports many
/// sites; this names the popular ones a user is likely to paste. Add entries here as needed.
public enum VideoPageDetector {
    public static let sites: [VideoPageSite] = [
        VideoPageSite(displayName: "YouTube", hostSuffixes: ["youtube.com", "youtu.be", "youtube-nocookie.com"]),
        VideoPageSite(displayName: "Vimeo", hostSuffixes: ["vimeo.com"]),
        VideoPageSite(displayName: "TikTok", hostSuffixes: ["tiktok.com"], prefersObservedMedia: true),
        VideoPageSite(displayName: "Twitch", hostSuffixes: ["twitch.tv"]),
        VideoPageSite(displayName: "Dailymotion", hostSuffixes: ["dailymotion.com", "dai.ly"]),
        VideoPageSite(
            displayName: "X", hostSuffixes: ["twitter.com", "x.com"],
            requiresObservedMedia: true, prefersObservedMedia: true
        ),
        VideoPageSite(displayName: "Facebook", hostSuffixes: ["facebook.com", "fb.watch"], prefersObservedMedia: true),
        VideoPageSite(
            displayName: "Instagram", hostSuffixes: ["instagram.com"],
            requiresObservedMedia: true, prefersObservedMedia: true
        ),
        VideoPageSite(
            displayName: "Reddit", hostSuffixes: ["reddit.com"],
            requiresObservedMedia: true, prefersObservedMedia: true
        ),
        VideoPageSite(displayName: "SoundCloud", hostSuffixes: ["soundcloud.com"]),
        VideoPageSite(displayName: "Bilibili", hostSuffixes: ["bilibili.com", "b23.tv"]),
        VideoPageSite(displayName: "Rumble", hostSuffixes: ["rumble.com"]),
        VideoPageSite(displayName: "Odysee", hostSuffixes: ["odysee.com", "lbry.tv"]),
        VideoPageSite(displayName: "TED", hostSuffixes: ["ted.com"]),
        VideoPageSite(displayName: "Loom", hostSuffixes: ["loom.com"]),
        VideoPageSite(displayName: "Medal", hostSuffixes: ["medal.tv"]),
        VideoPageSite(displayName: "Niconico", hostSuffixes: ["nicovideo.jp"]),
        VideoPageSite(displayName: "Bandcamp", hostSuffixes: ["bandcamp.com"]),
        VideoPageSite(displayName: "Mixcloud", hostSuffixes: ["mixcloud.com"]),
        VideoPageSite(displayName: "Kick", hostSuffixes: ["kick.com"]),
        VideoPageSite(displayName: "VK", hostSuffixes: ["vk.com"]),
        VideoPageSite(displayName: "Snapchat", hostSuffixes: ["snapchat.com"]),
        VideoPageSite(displayName: "Streamable", hostSuffixes: ["streamable.com"]),
        VideoPageSite(
            displayName: "Internet Archive", hostSuffixes: ["archive.org"],
            requiresObservedMedia: true, prefersObservedMedia: true
        ),
        VideoPageSite(
            displayName: "Tumblr", hostSuffixes: ["tumblr.com"],
            requiresObservedMedia: true, prefersObservedMedia: true
        ),
        VideoPageSite(
            displayName: "Imgur", hostSuffixes: ["imgur.com"],
            requiresObservedMedia: true, prefersObservedMedia: true
        ),
        VideoPageSite(
            displayName: "Flickr", hostSuffixes: ["flickr.com", "flic.kr"],
            requiresObservedMedia: true, prefersObservedMedia: true
        ),
        VideoPageSite(
            displayName: "LinkedIn", hostSuffixes: ["linkedin.com"],
            requiresObservedMedia: true, prefersObservedMedia: true
        ),
        VideoPageSite(
            displayName: "Pinterest", hostSuffixes: ["pinterest.com", "pinterest.ca", "pinterest.co.uk", "pin.it"],
            requiresObservedMedia: true, prefersObservedMedia: true
        ),
        VideoPageSite(
            displayName: "9GAG", hostSuffixes: ["9gag.com"],
            requiresObservedMedia: true, prefersObservedMedia: true
        ),
        VideoPageSite(
            displayName: "Bluesky", hostSuffixes: ["bsky.app", "main.bsky.dev"],
            requiresObservedMedia: true, prefersObservedMedia: true
        ),
        VideoPageSite(displayName: "Rutube", hostSuffixes: ["rutube.ru"]),
        VideoPageSite(displayName: "Wistia", hostSuffixes: ["wistia.com", "wistia.net"]),
        VideoPageSite(displayName: "AcFun", hostSuffixes: ["acfun.cn"]),
        VideoPageSite(displayName: "HIDIVE", hostSuffixes: ["hidive.com"]),
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
        guard let site = sites.first(where: { site in
            site.hostSuffixes.contains { suffix in
                // Exact host or a real subdomain (dot boundary), so `evilyoutube.com` never matches.
                host == suffix || host.hasSuffix("." + suffix)
            }
        }) else { return nil }
        // Popular sites put feeds, profiles, search, login, and help pages under non-root paths too.
        // Only actual watch/post routes should replace a direct browser sniff with yt-dlp; routing a
        // profile page could resolve a playlist (many files), which is exactly what the single-grab
        // browser affordance must never do.
        return matchesVideoRoute(site: site, url: url, host: host) ? site : nil
    }

    private static func matchesVideoRoute(site: VideoPageSite, url: URL, host: String) -> Bool {
        let components = url.path.split(separator: "/").map { $0.lowercased() }
        guard !components.isEmpty else { return false }

        switch site.displayName {
        case "YouTube", "Vimeo", "TikTok", "Twitch", "Dailymotion":
            return matchesVideoPlatformRoute(site.displayName, url: url, host: host, components: components)
        case "X", "Facebook", "Instagram", "Reddit":
            return matchesSocialVideoRoute(site.displayName, url: url, host: host, components: components)
        case "SoundCloud", "Bilibili":
            return matchesMediaRoute(site.displayName, host: host, components: components)
        case "Rumble", "Odysee", "TED", "Loom", "Medal", "Niconico":
            return matchesAlternativeVideoRoute(site.displayName, components: components)
        case "Bandcamp", "Mixcloud", "Kick", "VK", "Snapchat":
            return matchesCommunityMediaRoute(site.displayName, url: url, components: components)
        case "Tumblr", "Imgur", "Flickr", "LinkedIn", "Pinterest", "9GAG", "Bluesky":
            return matchesExpandedSocialRoute(site.displayName, url: url, host: host, components: components)
        case "Streamable", "Internet Archive", "Rutube", "Wistia", "AcFun", "HIDIVE":
            return matchesExpandedHostedRoute(site.displayName, components: components)
        default:
            return false
        }
    }

    private static func matchesVideoPlatformRoute(
        _ name: String, url: URL, host: String, components: [String]
    ) -> Bool {
        let first = components[0]
        switch name {
        case "YouTube":
            if host == "youtu.be" || host.hasSuffix(".youtu.be") { return components.count == 1 }
            if first == "watch" {
                return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .contains { $0.name.lowercased() == "v" && !($0.value ?? "").isEmpty } == true
            }
            return ["shorts", "live", "embed", "clip"].contains(first) && components.count >= 2
        case "Vimeo":
            // Canonical `/123`, player `/video/123`, channel `/channels/name/123`, review and
            // showcase routes end in the numeric video id. A number elsewhere in a collection URL
            // is not enough — that could hand a multi-item page to the one-grab affordance.
            if components.count == 1 { return first.allSatisfy(\.isNumber) }
            if first == "video" { return components.count == 2 && components[1].allSatisfy(\.isNumber) }
            return components.last?.allSatisfy(\.isNumber) == true
        case "TikTok":
            return (components.count >= 3 && first.hasPrefix("@") && components[1] == "video")
                || (host.hasPrefix("vm.") && components.count == 1)
        case "Twitch":
            // `/videos/123` is VOD; a single non-reserved component is a live channel.
            if first == "videos" { return components.count >= 2 && components[1].allSatisfy(\.isNumber) }
            if host.hasPrefix("clips.") { return components.count == 1 }
            if components.count == 3, components[1] == "clip" { return true }
            let reserved: Set<String> = ["directory", "downloads", "jobs", "p", "search", "settings", "store", "wallet"]
            return components.count == 1 && !reserved.contains(first)
        case "Dailymotion":
            if host == "dai.ly" || host.hasSuffix(".dai.ly") { return components.count == 1 }
            return (first == "video" && components.count >= 2)
                || (components.count >= 3 && first == "embed" && components[1] == "video")
        default:
            return false
        }
    }

    private static func matchesSocialVideoRoute(
        _ name: String, url: URL, host: String, components: [String]
    ) -> Bool {
        let first = components[0]
        switch name {
        case "X":
            return components.count >= 3 && components[1] == "status"
                && components[2].allSatisfy(\.isNumber)
        case "Facebook":
            if host == "fb.watch" || host.hasSuffix(".fb.watch") { return components.count == 1 }
            if first == "watch" {
                return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .contains { $0.name.lowercased() == "v" && !($0.value ?? "").isEmpty } == true
            }
            if first == "reel" { return components.count >= 2 }
            if let videos = components.firstIndex(of: "videos") { return videos + 1 < components.count }
            return false
        case "Instagram":
            return ["p", "reel", "reels", "tv"].contains(first) && components.count >= 2
        case "Reddit":
            if components.count >= 4 && first == "r" && components[2] == "comments" { return true }
            if components.count >= 2 && first == "comments" { return true }
            return components.count >= 4 && first == "user" && components[2] == "comments"
        default:
            return false
        }
    }

    private static func matchesMediaRoute(_ name: String, host: String, components: [String]) -> Bool {
        let first = components[0]
        switch name {
        case "SoundCloud":
            let reserved: Set<String> = ["discover", "search", "stream", "you"]
            return components.count == 2 && !reserved.contains(first) && components[1] != "sets"
        case "Bilibili":
            if host == "b23.tv" || host.hasSuffix(".b23.tv") { return components.count == 1 }
            return (first == "video" && components.count >= 2)
                || (components.count >= 3 && first == "bangumi" && components[1] == "play")
        default:
            return false
        }
    }

    private static func matchesAlternativeVideoRoute(_ name: String, components: [String]) -> Bool {
        let first = components[0]
        switch name {
        case "Rumble":
            return (first == "embed" && components.count >= 2)
                || (components.count == 1 && first.hasPrefix("v") && first.hasSuffix(".html"))
        case "Odysee":
            return components.count >= 2 && first.hasPrefix("@")
        case "TED":
            return first == "talks" && components.count >= 2
        case "Loom":
            return ["share", "embed"].contains(first) && components.count >= 2
        case "Medal":
            guard let clips = components.firstIndex(of: "clips") else { return false }
            return clips + 1 < components.count
        case "Niconico":
            return first == "watch" && components.count >= 2
        default:
            return false
        }
    }

    private static func matchesCommunityMediaRoute(
        _ name: String, url: URL, components: [String]
    ) -> Bool {
        let first = components[0]
        switch name {
        case "Bandcamp":
            return first == "track" && components.count == 2
        case "Mixcloud":
            let reserved: Set<String> = ["categories", "discover", "live", "search"]
            let collectionRoutes: Set<String> = ["favorites", "playlists", "uploads"]
            return components.count == 2 && !reserved.contains(first) && !collectionRoutes.contains(components[1])
        case "Kick":
            if components.count >= 3 && components[1] == "videos" { return true }
            if components.count != 1 { return false }
            let reserved: Set<String> = ["browse", "categories", "dashboard", "following", "search", "settings"]
            return !reserved.contains(first)
        case "VK":
            if first.firstMatch(of: /^video-?\d+_\d+$/) != nil { return true }
            guard first == "video_ext.php" else { return false }
            let queryNames = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { $0.name } ?? []
            return queryNames.contains("oid") && queryNames.contains("id")
        case "Snapchat":
            return first == "spotlight" && components.count >= 2
        default:
            return false
        }
    }

    private static func matchesExpandedSocialRoute(
        _ name: String, url: URL, host: String, components: [String]
    ) -> Bool {
        let first = components[0]
        switch name {
        case "Tumblr":
            if first == "post" { return components.count >= 2 && components[1].allSatisfy(\.isNumber) }
            return components.count >= 2 && components[1].allSatisfy(\.isNumber)
        case "Imgur":
            if !url.pathExtension.isEmpty { return false }
            if ["a", "gallery"].contains(first) { return components.count >= 2 }
            return components.count == 1
        case "Flickr":
            if host == "flic.kr" || host.hasSuffix(".flic.kr") { return components.count >= 1 }
            return components.count >= 3 && first == "photos" && components[2].allSatisfy(\.isNumber)
        case "LinkedIn":
            return first == "posts" || (components.count >= 2 && first == "feed" && components[1] == "update")
        case "Pinterest":
            if host == "pin.it" || host.hasSuffix(".pin.it") { return components.count == 1 }
            return first == "pin" && components.count >= 2
        case "9GAG":
            return first == "gag" && components.count == 2
        case "Bluesky":
            return components.count == 4 && first == "profile" && components[2] == "post"
        default:
            return false
        }
    }

    private static func matchesExpandedHostedRoute(_ name: String, components: [String]) -> Bool {
        let first = components[0]
        switch name {
        case "Streamable":
            if first == "e" || first == "s" { return components.count >= 2 }
            let reserved: Set<String> = ["login", "pricing", "signup", "upgrade"]
            return components.count == 1 && !reserved.contains(first)
        case "Internet Archive":
            return ["details", "embed"].contains(first) && components.count == 2
        case "Rutube":
            if first == "video" || first == "embed" { return components.count >= 2 }
            return components.count >= 3 && first == "play" && components[1] == "embed"
        case "Wistia":
            if first == "medias" { return components.count == 2 }
            return components.count >= 3 && first == "embed" && ["iframe", "medias"].contains(components[1])
        case "AcFun":
            return components.count >= 2 && ["v", "bangumi"].contains(first)
        case "HIDIVE":
            // The bundled extractor currently supports the legacy single-episode `/stream` route.
            // The newer `/video/{id}` page is intentionally left to browser sniffing/DRM detection.
            return first == "stream" && components.count >= 3
        default:
            return false
        }
    }
}
