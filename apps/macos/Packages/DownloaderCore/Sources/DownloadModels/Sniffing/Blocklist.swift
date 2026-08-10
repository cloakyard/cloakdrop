import Foundation

/// The downloadable blocklists the browser's ad blocker can use on top of its built-in curated
/// ruleset. Each is a maintained open-source *domain* list (block the domain and every subdomain —
/// the exact semantics of `AdBlockList`'s anchored host rules), small enough to fit WebKit's
/// 150,000-rules-per-list compile limit outright. Fetched only on user action (choosing a list or
/// pressing Update) — never automatically — per the app's privacy contract.
public enum BlocklistSource: String, CaseIterable, Sendable, Identifiable, Codable {
    /// The curated ruleset compiled into the app (`AdBlockList`) — no download, works offline.
    case builtIn
    /// OISD "small" (~56k domains) — curated for zero site breakage; ads, trackers, popups.
    case oisdSmall
    /// StevenBlack unified hosts (~78k domains, MIT) — the classic ads + malware hosts list.
    case stevenBlack
    /// Peter Lowe's ad-server list (~3.5k domains) — tiny, decades-maintained, ad/tracker hosts.
    case peterLowe

    public var id: String { rawValue }

    /// Where a fresh copy is fetched from (verified formats: OISD `domainswild2` = plain domains,
    /// StevenBlack = hosts file, Peter Lowe = plain domains). `nil` for the built-in ruleset.
    public var updateURL: URL? {
        switch self {
        case .builtIn:
            return nil
        case .oisdSmall:
            return URL(string: "https://small.oisd.nl/domainswild2")
        case .stevenBlack:
            return URL(string: "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts")
        case .peterLowe:
            return URL(string: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=nohtml&showintro=0&mimetype=plaintext")
        }
    }

    /// Sanity floor for a fetched payload: fewer parsed domains than this means a truncated,
    /// error-page, or wrong-format response — the update is rejected and the previous list kept.
    /// Set at a fraction of each list's real size (56k / 78k / 3.5k) so normal shrinkage passes.
    public var minimumExpectedDomains: Int {
        switch self {
        case .builtIn: return 0
        case .oisdSmall: return 10_000
        case .stevenBlack: return 20_000
        case .peterLowe: return 500
        }
    }
}

/// Metadata for a downloaded blocklist, persisted beside its domains file — what the settings UI
/// shows ("78,450 domains · updated today") and what survives relaunch.
public struct BlocklistInfo: Codable, Sendable, Equatable {
    public var source: BlocklistSource
    public var updatedAt: Date
    public var domainCount: Int

    public init(source: BlocklistSource, updatedAt: Date, domainCount: Int) {
        self.source = source
        self.updatedAt = updatedAt
        self.domainCount = domainCount
    }
}

/// Parses any of the common blocklist text formats into validated block domains. Format-agnostic
/// per line — plain domains (OISD, Peter Lowe), hosts files (`0.0.0.0 domain` — StevenBlack),
/// wildcards (`*.domain`), and bare-domain ABP lines (`||domain^`) all fold to the same thing.
///
/// Robustness is the point: the output feeds `AdBlockList` rule generation, so every domain is
/// validated down to a charset (`a-z 0-9 _ - .`) that is inert in a WebKit `url-filter` regex —
/// a hostile or corrupted list can drop entries but can never inject syntax. One malformed rule
/// would reject the whole compiled list and silently disable blocking.
public enum BlocklistParser {
    /// The outcome of a parse: sorted, deduped, suffix-pruned domains plus honesty counters.
    public struct Result: Sendable, Equatable {
        /// Validated domains, lowercased, sorted (stable output → stable rule-list identifier).
        public var domains: [String]
        /// Non-comment lines that failed extraction/validation (junk tolerated, but counted).
        public var skipped: Int
        /// True when the list exceeded `maxDomains` and was cut at the cap.
        public var truncated: Bool

        public init(domains: [String] = [], skipped: Int = 0, truncated: Bool = false) {
            self.domains = domains
            self.skipped = skipped
            self.truncated = truncated
        }
    }

    /// Hard cap under WebKit's 150,000-rules-per-list compile limit, with headroom.
    public static let maxDomains = 145_000

    /// Hosts-file names that are infrastructure, never blockable content.
    static let junkNames: Set<String> = [
        "localhost", "localhost.localdomain", "local", "localdomain", "broadcasthost"
    ]

    public static func parse(_ text: String) -> Result {
        guard let result = parse(text, isCancelled: { false }) else {
            preconditionFailure("A non-cancellable blocklist parse cannot be cancelled")
        }
        return result
    }

    /// The app's off-main parser entry point. It checks cooperative task cancellation throughout
    /// line ingestion and suffix pruning so changing sources does not leave an obsolete large parse
    /// consuming CPU and memory in the background.
    public static func parseCancellable(_ text: String) throws -> Result {
        let result = parse(text) {
            withUnsafeCurrentTask { $0?.isCancelled ?? false }
        }
        guard let result else { throw CancellationError() }
        return result
    }

    private static func parse(_ text: String, isCancelled: @escaping () -> Bool) -> Result? {
        var kept: Set<String> = []
        var skipped = 0
        var truncated = false
        var lineCount = 0
        var wasCancelled = false
        text.enumerateLines { rawLine, stop in
            lineCount += 1
            if lineCount.isMultiple(of: 256), isCancelled() {
                wasCancelled = true
                stop = true
                return
            }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return }
            // Whole-line comments and ABP section headers.
            if line.hasPrefix("#") || line.hasPrefix("!") || line.hasPrefix("[") { return }
            // Trailing same-line comments (`domain.com # promo`).
            let payload = line.firstIndex(of: "#").map { String(line[..<$0]).trimmingCharacters(in: .whitespaces) } ?? line
            guard !payload.isEmpty else { return }
            if let domain = extractDomain(payload) {
                guard !kept.contains(domain) else { return }
                guard kept.count < maxDomains else {
                    truncated = true
                    stop = true
                    return
                }
                kept.insert(domain)
            } else {
                skipped += 1
            }
        }
        guard !wasCancelled, !isCancelled(),
              let pruned = pruneCovered(kept, isCancelled: isCancelled) else { return nil }
        let domains = pruned.sorted()
        guard !isCancelled() else { return nil }
        return Result(domains: domains, skipped: skipped, truncated: truncated)
    }

    /// Whether `host` (a URL host, possibly `host:port`) is one of `domains` or a subdomain of one —
    /// the suffix-match twin of `AdBlockList.isBlockedHost`, O(label count) against a set. Used to
    /// reject ad-serving popups against the downloaded list.
    public static func covers(host: String, domains: Set<String>) -> Bool {
        guard !domains.isEmpty else { return false }
        var candidate = host.lowercased()
        if let colon = candidate.firstIndex(of: ":") { candidate = String(candidate[..<colon]) }
        while !candidate.isEmpty {
            if domains.contains(candidate) { return true }
            guard let dot = candidate.firstIndex(of: ".") else { return false }
            candidate = String(candidate[candidate.index(after: dot)...])
        }
        return false
    }

    // MARK: - Internals

    /// One non-comment line → a validated block domain, or `nil` for anything unrecognized. Never
    /// guesses: a line carrying real ABP syntax (paths, separators, options, exceptions) is not a
    /// domain entry and must not be mangled into one.
    static func extractDomain(_ payload: String) -> String? {
        var candidate: Substring
        let tokens = payload.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if tokens.count >= 2 {
            // Hosts-file form: `<redirect-ip> <domain> [aliases…]`. Anything else multi-token is junk.
            guard let first = tokens.first, isRedirectIP(first) else { return nil }
            candidate = tokens[1]
        } else if let only = tokens.first {
            candidate = only
        } else {
            return nil
        }
        // Bare-domain ABP form: `||domain^` (exceptions and rules with any other syntax are not ours).
        if candidate.hasPrefix("@@") { return nil }
        if candidate.hasPrefix("||") { candidate = candidate.dropFirst(2) }
        if candidate.hasSuffix("^") { candidate = candidate.dropLast() }
        // Wildcard-domain form: `*.domain` (and tolerate a stray leading/trailing dot).
        if candidate.hasPrefix("*.") { candidate = candidate.dropFirst(2) }
        while candidate.hasPrefix(".") { candidate = candidate.dropFirst() }
        while candidate.hasSuffix(".") { candidate = candidate.dropLast() }
        let domain = candidate.lowercased()
        return isValidBlockDomain(domain) ? domain : nil
    }

    /// The redirect targets hosts files use (`0.0.0.0 domain`, `127.0.0.1 domain`, IPv6 loopbacks).
    static func isRedirectIP(_ token: Substring) -> Bool {
        if token.contains(":") { return true }   // any IPv6 literal (::, ::1, fe80::1%lo0)
        return token == "0.0.0.0" || token == "127.0.0.1" || token == "255.255.255.255"
    }

    /// Strict LDH validation. This is a *security boundary*: everything that passes is embeddable
    /// verbatim in a content-rule `url-filter` regex (after dot-escaping) and in JSON.
    static func isValidBlockDomain(_ domain: String) -> Bool {
        guard domain.count <= 253, domain.contains("."), !junkNames.contains(domain) else { return false }
        var labels = 0
        for label in domain.split(separator: ".", omittingEmptySubsequences: false) {
            guard (1...63).contains(label.count) else { return false }
            guard label.first != "-", label.last != "-" else { return false }
            guard label.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-" || $0 == "_") }) else {
                return false
            }
            labels += 1
        }
        guard labels >= 2 else { return false }
        // An all-digit final label is an IPv4 literal or a malformed name, never a public domain.
        if let tld = domain.split(separator: ".").last, tld.allSatisfy(\.isNumber) { return false }
        return true
    }

    /// Drop every domain whose parent is also listed — the parent's subdomain-suffix rule already
    /// covers it. Fewer rules, identical coverage, more headroom under the compile cap.
    private static func pruneCovered(_ domains: Set<String>, isCancelled: () -> Bool) -> Set<String>? {
        var inspected = 0
        var wasCancelled = false
        let pruned = domains.filter { domain in
            inspected += 1
            if inspected.isMultiple(of: 256), isCancelled() {
                wasCancelled = true
                return false
            }
            var parent = Substring(domain)
            while let dot = parent.firstIndex(of: ".") {
                parent = parent[parent.index(after: dot)...]
                guard parent.contains(".") else { break }   // a bare TLD can never be in the set
                if domains.contains(String(parent)) { return false }
            }
            return true
        }
        return wasCancelled || isCancelled() ? nil : pruned
    }
}
