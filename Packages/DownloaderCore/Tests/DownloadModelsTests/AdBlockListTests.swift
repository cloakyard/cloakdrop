import Foundation
import Testing
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
        // doubleclick.net (seeded from the sniffer) is present, anchored at the scheme, dots escaped.
        #expect(filters.contains("^https?://([^/]+\\.)?doubleclick\\.net"))
        // No raw unescaped host dots leak into a filter.
        #expect(!filters.contains { $0.contains("doubleclick.net") && !$0.contains("doubleclick\\.net") })
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
}
