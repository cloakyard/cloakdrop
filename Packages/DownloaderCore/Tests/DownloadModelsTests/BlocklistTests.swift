import Foundation
import Testing
import WebKit
@testable import DownloadModels

/// The downloadable-blocklist pipeline: format-agnostic parsing, the strict domain validation that
/// makes list content inert in WebKit rule regexes, suffix pruning, and external rule generation.
@Suite("Blocklist parsing & external rules")
struct BlocklistTests {
    // MARK: - Formats (fixtures mirror the real lists, verified live)

    @Test("Plain-domain lists (OISD/Peter Lowe): comments skipped, domains kept")
    func plainDomains() {
        let text = """
        # Version: 202607100312
        # Title: oisd small
        # Entry: "example.com" should block subdomains too

        0-02.net
        000webhostapp.com
        ads.example.co.uk
        """
        let result = BlocklistParser.parse(text)
        #expect(result.domains == ["0-02.net", "000webhostapp.com", "ads.example.co.uk"])
        #expect(result.skipped == 0)
        #expect(!result.truncated)
    }

    @Test("Hosts files (StevenBlack): redirect IPs stripped, loopback/junk names dropped")
    func hostsFormat() {
        let text = """
        # Title: StevenBlack/hosts
        127.0.0.1 localhost
        127.0.0.1 localhost.localdomain
        127.0.0.1 local
        255.255.255.255 broadcasthost
        ::1 localhost
        ::1 ip6-localhost
        fe80::1%lo0 localhost
        0.0.0.0 0.0.0.0
        0.0.0.0 ads.tracker.example
        0.0.0.0 Analytics.Example.COM
        """
        let result = BlocklistParser.parse(text)
        #expect(result.domains == ["ads.tracker.example", "analytics.example.com"])
        // ip6-localhost (no dot) and 0.0.0.0 (all-digit) are invalid, the rest are junk names —
        // all rejected, none crash the parse.
        #expect(result.skipped > 0)
    }

    @Test("Bare-domain ABP lines fold to domains; real ABP syntax is rejected, not mangled")
    func abpFormat() {
        let text = """
        [Adblock Plus 2.0]
        ! Homepage: https://example.org
        ||ads.example.com^
        ||tracker.example.net^
        @@||goodsite.example.com^
        ||ads.example.com^$third-party
        ||example.com/banner/*
        /banner/ads/*
        ##.ad-container
        """
        let result = BlocklistParser.parse(text)
        #expect(result.domains == ["ads.example.com", "tracker.example.net"])
        // Exception, optioned, path, and cosmetic rules are not domain entries.
        #expect(result.skipped == 4)
    }

    @Test("Wildcards, stray dots, CRLF, tabs, and inline comments all normalize")
    func normalization() {
        let text = "*.wild.example\r\n.leading.example\r\ntrailing.example.\r\n"
            + "0.0.0.0\tads.tabbed.example\t# tail comment\r\nspaced.example   # promo\r\n"
        let result = BlocklistParser.parse(text)
        #expect(result.domains == [
            "ads.tabbed.example", "leading.example", "spaced.example", "trailing.example", "wild.example"
        ])
        #expect(result.skipped == 0)
    }

    // MARK: - Validation as a security boundary

    @Test("Hostile or malformed entries can never reach rule generation")
    func validationBoundary() {
        let hostile = """
        evil.com/../../etc
        evil.com]|[injection
        (evil).com
        evil..com
        -evil.com
        evil-.com
        evil.com:8080
        just-one-label
        10.0.0.1
        münchen.example
        a b c.com
        \(String(repeating: "a", count: 64)).example.com
        \(String(repeating: "long.", count: 60))example.com
        """
        let result = BlocklistParser.parse(hostile)
        #expect(result.domains.isEmpty)
        #expect(result.skipped == 13)
    }

    @Test("Valid edge cases survive: digits, hyphens, underscores, punycode, deep nesting")
    func validEdgeCases() {
        let text = """
        0-02.net
        xn--mnchen-3ya.example
        _dmarc.weird.example
        a.b.c.d.e.f.example.com
        123.abc
        """
        let result = BlocklistParser.parse(text)
        #expect(result.domains.count == 5)
        #expect(result.skipped == 0)
    }

    @Test("Every parsed domain is inert in a url-filter regex (charset whitelist)")
    func regexInertCharset() {
        let text = "ads.example.com\n0-02.net\n_dmarc.weird.example\nxn--p1ai.example"
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
        for domain in BlocklistParser.parse(text).domains {
            #expect(domain.allSatisfy { allowed.contains($0) }, "unexpected character in \(domain)")
        }
    }

    // MARK: - Dedupe, pruning, cap

    @Test("Duplicates collapse and subdomains of a listed parent are pruned")
    func dedupeAndPrune() {
        let text = """
        ads.example.com
        ads.example.com
        sub.ads.example.com
        deep.sub.ads.example.com
        other.example.com
        example.org
        tracker.example.org
        """
        let result = BlocklistParser.parse(text)
        // ads.example.com's children are covered by the suffix rule; example.org covers its child.
        #expect(result.domains == ["ads.example.com", "example.org", "other.example.com"])
    }

    @Test("Pruning never drops a domain whose parent is NOT listed")
    func pruneKeepsUncovered() {
        let result = BlocklistParser.parse("sub.a.example\nsub.b.example")
        #expect(result.domains == ["sub.a.example", "sub.b.example"])
    }

    @Test("Oversized lists are cut at the WebKit-safe cap and flagged")
    func capEnforced() {
        var lines: [String] = []
        lines.reserveCapacity(BlocklistParser.maxDomains + 100)
        for index in 0..<(BlocklistParser.maxDomains + 100) {
            lines.append("d\(index).example")
        }
        let result = BlocklistParser.parse(lines.joined(separator: "\n"))
        #expect(result.domains.count == BlocklistParser.maxDomains)
        #expect(result.truncated)
    }

    @Test("Empty and comment-only input yields an empty result, not an error")
    func emptyInput() {
        #expect(BlocklistParser.parse("").domains.isEmpty)
        #expect(BlocklistParser.parse("# only\n! comments\n\n").domains.isEmpty)
    }

    // MARK: - Host coverage (popup rejection)

    @Test("covers() matches the domain and subdomains, strips ports, rejects look-alikes")
    func coversSemantics() {
        let domains: Set<String> = ["ads.example.com", "tracker.net"]
        #expect(BlocklistParser.covers(host: "ads.example.com", domains: domains))
        #expect(BlocklistParser.covers(host: "sub.ads.example.com", domains: domains))
        #expect(BlocklistParser.covers(host: "ADS.EXAMPLE.COM", domains: domains))
        #expect(BlocklistParser.covers(host: "tracker.net:8443", domains: domains))
        #expect(!BlocklistParser.covers(host: "notads.example.com", domains: domains))
        #expect(!BlocklistParser.covers(host: "tracker.network.com", domains: domains))
        #expect(!BlocklistParser.covers(host: "example.com", domains: domains))
        #expect(!BlocklistParser.covers(host: "anything.at.all", domains: []))
    }

    // MARK: - External rule generation

    @Test("External rules JSON: one anchored block rule per domain, end-of-host anchored")
    func externalRules() throws {
        let json = AdBlockList.externalRulesJSON(blocking: ["ads.example.com", "media.net"])
        let data = try #require(json.data(using: .utf8))
        let rules = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(rules.count == 2)
        let filters = rules.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
        #expect(filters.contains("^https?://([^/]+\\.)?media\\.net[:/]"))
        func blocked(_ url: String) -> Bool {
            filters.contains { url.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
        }
        #expect(blocked("https://media.net/ad.js"))
        #expect(blocked("https://cdn.ads.example.com/x"))
        #expect(!blocked("https://media.netflix.com/video.mp4"))   // the anchoring regression
    }

    @Test("External identifiers are content-hashed and disjoint from the curated identifier")
    func externalIdentifiers() {
        let one = AdBlockList.externalIdentifier(forJSON: "a")
        let two = AdBlockList.externalIdentifier(forJSON: "b")
        #expect(one != two)
        #expect(one.hasPrefix(AdBlockList.externalIdentifierPrefix))
        #expect(one.hasPrefix(AdBlockList.identifierPrefix))       // one eviction sweep covers both
        #expect(!AdBlockList.identifier.hasPrefix(AdBlockList.externalIdentifierPrefix))
    }

    @Test("A parsed real-world-shaped list compiles in WebKit's content-rule compiler")
    @MainActor
    func externalRulesCompileInWebKit() async throws {
        let text = """
        0.0.0.0 ads.tracker.example
        ||banner.example.net^
        *.popups.example.org
        0-02.net
        xn--mnchen-3ya.example
        _metrics.weird.example
        """
        let parsed = BlocklistParser.parse(text)
        #expect(parsed.domains.count == 6)
        let json = AdBlockList.externalRulesJSON(blocking: parsed.domains)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocklist-compile-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(WKContentRuleListStore(url: directory))
        let list: WKContentRuleList? = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: AdBlockList.externalIdentifier(forJSON: json),
                                         encodedContentRuleList: json) { list, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: list)
                }
            }
        }
        #expect(list != nil)
    }

    // MARK: - Sources

    @Test("Every downloadable source has an https update URL and a sane validation floor")
    func sourceCatalog() {
        for source in BlocklistSource.allCases {
            if source == .builtIn {
                #expect(source.updateURL == nil)
                continue
            }
            let url = source.updateURL
            #expect(url?.scheme == "https", "\(source) must fetch over TLS")
            #expect(source.minimumExpectedDomains > 0)
            #expect(source.minimumExpectedDomains < BlocklistParser.maxDomains)
        }
    }
}
