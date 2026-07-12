import Foundation
import Testing
import WebKit
@testable import DownloadModels

/// The ad/tracker blocking ruleset: the JSON must be well-formed WebKit content-rule-list data,
/// the host anchoring must not over- or under-match, and popup classification must be exact.
@Suite("Ad-block ruleset")
struct AdBlockListTests {
    @Test("Emits valid content-rule-list JSON: an array of trigger/action rules")
    func validJSON() throws {
        let data = try #require(AdBlockList.json.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data)
        let rules = try #require(parsed as? [[String: Any]])
        // A block rule per host + per path fragment, plus one cosmetic rule.
        #expect(rules.count == AdBlockList.blockedHosts.count + AdBlockList.blockedPathFragments.count + 1)
        for rule in rules {
            #expect(rule["trigger"] is [String: Any])
            #expect(rule["action"] is [String: Any])
        }
    }

    @Test("Every ad host compiles to an anchored, dot-escaped block rule")
    func hostRules() throws {
        let data = try #require(AdBlockList.json.data(using: .utf8))
        let rules = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let filters = rules.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
        // doubleclick.net (seeded from the sniffer) is present, anchored at the scheme AND at the
        // end of the host, dots escaped.
        #expect(filters.contains("^https?://([^/]+\\.)?doubleclick\\.net[:/]"))
        // No raw unescaped host dots leak into a filter.
        #expect(!filters.contains { $0.contains("doubleclick.net") && !$0.contains("doubleclick\\.net") })
    }

    @Test("Host filters match the host and its subdomains — never a longer host sharing the prefix")
    func hostFilterAnchoring() throws {
        let data = try #require(AdBlockList.json.data(using: .utf8))
        let rules = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        // Only the host-block filters (anchored at the scheme) — not path fragments or the cosmetic rule.
        let hostFilters = rules.compactMap { rule -> String? in
            guard let filter = (rule["trigger"] as? [String: Any])?["url-filter"] as? String,
                  filter.hasPrefix("^https?://") else { return nil }
            return filter
        }
        #expect(hostFilters.count == AdBlockList.blockedHosts.count)
        func blocked(_ url: String) -> Bool {
            hostFilters.contains { url.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
        }
        // The real hosts, their subdomains, and explicit ports are blocked…
        #expect(blocked("https://media.net/ad.js"))
        #expect(blocked("https://cdn.media.net/ad.js"))
        #expect(blocked("https://pubads.g.doubleclick.net/gampad/ads"))
        #expect(blocked("http://adjust.com:8080/track"))
        // …but a longer registrable host that merely *starts* with a blocked one is not
        // (the pre-anchor regression: media.net matched media.netflix.com).
        #expect(!blocked("https://media.netflix.com/video.mp4"))
        #expect(!blocked("https://adjust.company.example/page"))
        // Nor a look-alike suffix host, or the host smuggled into a path or query.
        #expect(!blocked("https://notdoubleclick.net/x"))
        #expect(!blocked("https://example.com/doubleclick.net/asset"))
        #expect(!blocked("https://example.com/?u=doubleclick.net"))
    }

    @Test("The cosmetic rule hides ad containers site-wide")
    func cosmeticRule() throws {
        let data = try #require(AdBlockList.json.data(using: .utf8))
        let rules = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let cosmetic = try #require(rules.first { ($0["action"] as? [String: Any])?["type"] as? String == "css-display-none" })
        #expect((cosmetic["trigger"] as? [String: Any])?["url-filter"] as? String == ".*")
        let selector = try #require((cosmetic["action"] as? [String: Any])?["selector"] as? String)
        #expect(selector.contains(".adsbygoogle"))
    }

    @Test("Path fragments block third-party only")
    func pathRulesAreThirdPartyOnly() throws {
        let data = try #require(AdBlockList.json.data(using: .utf8))
        let rules = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let pageadRule = try #require(rules.first {
            (($0["trigger"] as? [String: Any])?["url-filter"] as? String) == "/pagead/"
        })
        let loadType = (pageadRule["trigger"] as? [String: Any])?["load-type"] as? [String]
        #expect(loadType == ["third-party"])
    }

    @Test("isBlockedHost matches the host and its subdomains, not look-alikes")
    func hostClassification() {
        #expect(AdBlockList.isBlockedHost("doubleclick.net"))
        #expect(AdBlockList.isBlockedHost("pubads.g.doubleclick.net"))
        #expect(AdBlockList.isBlockedHost("DOUBLECLICK.NET"))   // case-insensitive
        // A look-alike that merely ends with the same letters is not a subdomain.
        #expect(!AdBlockList.isBlockedHost("notdoubleclick.net"))
        #expect(!AdBlockList.isBlockedHost("example.com"))
        // The Yandex metrica tracker is blocked; yandex.ru itself is not.
        #expect(AdBlockList.isBlockedHost("mc.yandex.ru"))
        #expect(!AdBlockList.isBlockedHost("yandex.ru"))
    }

    @Test("Identifier is stable across calls and versioned by content")
    func identifierStability() {
        #expect(AdBlockList.identifier == AdBlockList.identifier)
        #expect(AdBlockList.identifier.hasPrefix(AdBlockList.identifierPrefix))
        // The hash tracks content: different input, different digest.
        #expect(AdBlockList.stableHash("a") != AdBlockList.stableHash("b"))
        #expect(AdBlockList.stableHash("cloak") == AdBlockList.stableHash("cloak"))
    }

    @Test("The sniffer's ad hosts are a subset of the blocklist (single source of truth)")
    func reusesSnifferHosts() {
        for host in MediaSniffer.adHostSuffixes {
            #expect(AdBlockList.blockedHosts.contains(host), "\(host) missing from the blocklist")
        }
    }

    /// The ruleset must compile in *WebKit's* url-filter dialect (a strict regex subset — no `|`,
    /// no look-around), not just parse as JSON: one bad filter rejects the whole list and the app
    /// fails open (browsing silently unblocked). Compiling with the real WKContentRuleListStore is
    /// the only faithful check — this is the single WebKit import in the core's test suite, and it
    /// stays out of the library targets.
    @Test("The emitted JSON compiles in WebKit's content-rule compiler")
    @MainActor
    func compilesInWebKit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("adblock-compile-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(WKContentRuleListStore(url: directory))
        let list: WKContentRuleList? = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: AdBlockList.identifier,
                                         encodedContentRuleList: AdBlockList.json) { list, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: list)
                }
            }
        }
        #expect(list != nil)
    }
}
