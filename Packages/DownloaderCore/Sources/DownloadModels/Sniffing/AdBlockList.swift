import Foundation

/// The content-blocking ruleset for the built-in browser, expressed as a WebKit **content rule
/// list** (the same JSON format Safari content blockers use). WebKit compiles this to bytecode and
/// enforces it in its networking process, so ad/tracker requests are dropped *before* they leave the
/// device — robust across virtually every site, with no per-page scripting and no third-party
/// dependency. This type is pure data (no WebKit import) so the ruleset is unit-tested here; the app
/// layer compiles and applies it (see `BrowserStore`).
///
/// Three layers, mirroring how real blockers work:
///  1. **Network block** — a rule per known ad/tracker host, anchored so `notdoubleclick.net` and a
///     `?u=doubleclick.net` query never match, only the real host and its subdomains.
///  2. **Path block** — a small, high-confidence set of ad URL fragments (`/pagead/`, `/adsense/`),
///     third-party only, to catch ads proxied through a first-party domain.
///  3. **Cosmetic hide** — `display:none` for unambiguous ad containers, so a blocked ad leaves no
///     empty gap.
///
/// Off by default; the user opts in from Settings ▸ Browser. Downloads (the engine's own URLSession
/// transfers) are never subject to this list — only in-browser page loads are.
public enum AdBlockList {
    /// Ad-network, ad-exchange, and analytics/tracker hosts to block outright. Matched on the
    /// registrable host so every subdomain is covered. Seeded from the sniffer's ad-host set (single
    /// source of truth for "this host only ever serves ads") and broadened with the tracker/telemetry
    /// and pop/push-ad networks a general blocker needs. Deliberately excludes hosts that also carry
    /// sign-in or first-party app functionality (e.g. `connect.facebook.net`, tag managers) so the
    /// blocker can't lock a user out of a site.
    public static let blockedHosts: [String] = {
        let trackers = [
            // Analytics / measurement / session-replay.
            "google-analytics.com", "scorecardresearch.com", "quantserve.com", "quantcount.com",
            "hotjar.com", "mixpanel.com", "segment.io", "amplitude.com", "fullstory.com",
            "mouseflow.com", "crazyegg.com", "chartbeat.com", "chartbeat.net", "parsely.com",
            "imrworldwide.com", "sail-horizon.com", "mc.yandex.ru", "bat.bing.com",
            // Mobile-attribution / marketing.
            "branch.io", "appsflyer.com", "adjust.com", "kochava.com", "ads-twitter.com",
            // Adobe Experience Cloud trackers, and data-broker / DMP identity graphs.
            "omtrdc.net", "demdex.net", "everesttech.net", "2o7.net", "krxd.net", "bluekai.com",
            "crwdcntrl.net", "agkn.com", "exelator.com", "tapad.com", "rlcdn.com", "adsymptotic.com",
            // Pop-under / push-notification ad networks — the biggest source of "unwanted popups".
            "ad-maven.com", "clickadu.com", "onclickads.net", "pushnami.com", "pushengage.com",
            "izooto.com", "pushwoosh.com", "carbonads.com"
        ]
        // Dedupe against the sniffer's list and sort for a stable, hashable ruleset.
        return Array(Set(MediaSniffer.adHostSuffixes + trackers)).sorted()
    }()

    /// High-confidence ad URL-path fragments, blocked only for third-party loads so a first-party
    /// page that legitimately contains one of these strings in its own path isn't broken. Kept small
    /// on purpose — path matching is where over-blocking breaks sites.
    public static let blockedPathFragments: [String] = [
        "/pagead/", "/pagead2/", "/adsense/", "/adframe", "/ad-frame", "/adserver/",
        "/gpt/pubads", "/prebid", "/ad_analytics", "/googlesyndication"
    ]

    /// Unambiguous ad-container selectors hidden with `display:none` so a blocked ad leaves no gap.
    /// Conservative by design: only ids/classes/attributes that are ads by convention — never generic
    /// tokens like `.ad`, `.ads`, or `.banner` that legitimate layouts reuse.
    public static let cosmeticSelectors: [String] = [
        ".adsbygoogle", "ins.adsbygoogle",
        "[id^=\"google_ads_\"]", "[id^=\"google_ads_iframe\"]", "[id^=\"div-gpt-ad\"]",
        "[id^=\"dfp-ad\"]", "[id^=\"ad-slot\"]", "[id^=\"banner-ad\"]",
        "[class^=\"adsbygoogle\"]", "[class*=\"ad-placeholder\"]",
        "[data-ad-slot]", "[data-adunit]",
        "iframe[src*=\"doubleclick.net\"]", "iframe[src*=\"googlesyndication.com\"]",
        "iframe[id^=\"google_ads_iframe\"]",
        ".advertisement", ".ad-banner", ".ad-container", ".ad-wrapper", ".sponsored-content"
    ]

    /// The compiled ruleset JSON in WebKit's content-rule-list format. Built with `Codable` (always
    /// valid, correctly escaped JSON) with sorted keys so the output is byte-for-byte stable — the
    /// identifier below hashes it, and an unstable string would recompile the list on every launch.
    /// Computed once.
    public static let json: String = {
        var rules: [Rule] = []
        for host in blockedHosts {
            rules.append(Rule(
                trigger: Trigger(urlFilter: hostFilter(host), loadType: nil),
                action: Action(type: "block", selector: nil)
            ))
        }
        for fragment in blockedPathFragments {
            rules.append(Rule(
                trigger: Trigger(urlFilter: escapeForFilter(fragment), loadType: ["third-party"]),
                action: Action(type: "block", selector: nil)
            ))
        }
        rules.append(Rule(
            trigger: Trigger(urlFilter: ".*", loadType: nil),
            action: Action(type: "css-display-none", selector: cosmeticSelectors.joined(separator: ", "))
        ))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(rules)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "[]"
    }()

    /// A stable identifier for the compiled list, embedding a content hash so WebKit recompiles
    /// automatically whenever the ruleset changes (no manual version bump). Computed once.
    public static let identifier: String = "cloakdrop-adblock-\(stableHash(json))"

    /// The shared prefix of every identifier this type produces, so the app can evict stale
    /// (older-version) compiled lists.
    public static let identifierPrefix = "cloakdrop-adblock-"

    /// Whether `host` is a blocked ad/tracker host (exact or a subdomain of one) — used to reject
    /// ad-serving popups, which the network rules can't see because a popup is a new top-level load.
    public static func isBlockedHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return blockedHosts.contains { normalized == $0 || normalized.hasSuffix("." + $0) }
    }

    // MARK: - Internals

    /// Anchor a host at the scheme so only the real host (and its subdomains) match — never the host
    /// appearing later in a path or query, and never a longer host that merely ends the same way.
    private static func hostFilter(_ host: String) -> String {
        "^https?://([^/]+\\.)?" + escapeForFilter(host)
    }

    /// Escape a literal for a content-rule `url-filter` regex (dots are the only metacharacter our
    /// hosts/fragments contain).
    private static func escapeForFilter(_ literal: String) -> String {
        literal.replacingOccurrences(of: ".", with: "\\.")
    }

    /// A launch-stable hash (djb2) — `Hasher` is per-process-seeded, so it can't key an on-disk
    /// compiled list across launches.
    static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }

    private struct Rule: Encodable {
        let trigger: Trigger
        let action: Action
    }

    private struct Trigger: Encodable {
        let urlFilter: String
        let loadType: [String]?
        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case loadType = "load-type"
        }
    }

    private struct Action: Encodable {
        let type: String
        let selector: String?
    }
}
