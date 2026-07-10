import WebKit
import DownloadModels

/// Why a blocklist update failed — every case renders as a one-line, user-facing explanation.
/// Plain URL errors (offline, timeout) propagate as themselves; these cover the rest.
enum BlocklistUpdateError: LocalizedError {
    case badStatus(Int)
    case unreadablePayload
    case payloadTooLarge
    case tooFewDomains(Int)
    case compileFailed

    var errorDescription: String? {
        switch self {
        case .badStatus(let code):
            return String(localized: "The list server answered with an error (HTTP \(code)).")
        case .unreadablePayload:
            return String(localized: "The server’s response wasn’t a readable blocklist.")
        case .payloadTooLarge:
            return String(localized: "The downloaded list is unreasonably large.")
        case .tooFewDomains(let count):
            return String(localized: "The downloaded list looks incomplete (\(count) entries) — keeping the previous copy.")
        case .compileFailed:
            return String(localized: "The list couldn’t be compiled for WebKit.")
        }
    }
}

// MARK: - Downloadable blocklists
//
// Lifecycle: the user's chosen source is `activeBlocklistSource` (set eagerly, before any await).
// `activateBlocklist` loads + compiles the *stored* copy — no network, safe at launch.
// `updateBlocklist` is the only network path — user-initiated exclusively (choosing a list or
// pressing Update; never on a timer, never at launch). Every step re-validates from scratch
// (stored files are parsed again, never trusted), replaces state only after full success, and
// re-checks the active source after each await so a mid-flight switch can't install a stale list.
// Any failure leaves the previous list — or the curated baseline — in effect: fail-open, never broken.
extension BrowserStore {
    /// Fetched payloads beyond this are rejected outright (the real lists are 1–4 MB).
    static let maxBlocklistPayloadBytes = 32 * 1024 * 1024

    /// Everything `setAdBlock` should attach: the curated list plus the external one when active.
    var activeRuleLists: [WKContentRuleList] {
        [adBlockRuleList, externalRuleList].compactMap { $0 }
    }

    /// Popup rejection against the curated hosts AND the active downloaded list.
    func isBlockedPopupHost(_ host: String) -> Bool {
        AdBlockList.isBlockedHost(host) || BlocklistParser.covers(host: host, domains: externalDomains)
    }

    /// Make `source` the active blocklist using its *stored* copy (no network). For `.builtIn` —
    /// or when nothing is stored yet — the external list simply comes off and the curated ruleset
    /// stands alone.
    func activateBlocklist(_ source: BlocklistSource) async {
        activeBlocklistSource = source
        externalRuleList = nil
        externalDomains = []
        externalInfo = nil
        guard source != .builtIn,
              let file = try? Self.domainsFile(for: source),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let parsed = await Self.parseOffMain(text)
        // The stored copy gets the same floor as a fresh download — a corrupted file must not
        // silently shrink blocking to a handful of rules.
        guard parsed.domains.count >= source.minimumExpectedDomains else { return }
        let info = Self.readInfo(for: source)
            ?? BlocklistInfo(source: source, updatedAt: .distantPast, domainCount: parsed.domains.count)
        try? await installCompiled(domains: parsed.domains, for: source, info: info)
    }

    /// Fetch a fresh copy of `source`, validate it, persist it, and (if the user hasn't switched
    /// away meanwhile) compile + activate it. Throws with the previous list still in effect.
    @discardableResult
    func updateBlocklist(for source: BlocklistSource) async throws -> BlocklistInfo {
        guard let url = source.updateURL else {
            return BlocklistInfo(source: .builtIn, updatedAt: Date(), domainCount: AdBlockList.blockedHosts.count)
        }
        let text = try await Self.fetchList(from: url, proxies: browsingProxyConfigurations)
        let parsed = await Self.parseOffMain(text)
        guard parsed.domains.count >= source.minimumExpectedDomains else {
            throw BlocklistUpdateError.tooFewDomains(parsed.domains.count)
        }
        let info = BlocklistInfo(source: source, updatedAt: Date(), domainCount: parsed.domains.count)
        // Persist the canonical (validated, pruned) domains, not the raw payload — cheap to reload
        // and already invariant-checked. Atomic writes; metadata second so it never describes a
        // file that isn't there.
        try Self.persist(domains: parsed.domains, info: info, for: source)
        if activeBlocklistSource == source {
            try await installCompiled(domains: parsed.domains, for: source, info: info)
        }
        return info
    }

    /// The stored metadata for `source`, if a copy has been downloaded before.
    func storedBlocklistInfo(for source: BlocklistSource) -> BlocklistInfo? {
        Self.readInfo(for: source)
    }

    // MARK: - Compile & install

    /// Generate rules (off-main — it's megabytes of JSON), compile via WebKit's cached store, and
    /// install. Re-checks the active source around every await; sweeps stale bytecode on success.
    private func installCompiled(domains: [String], for source: BlocklistSource, info: BlocklistInfo) async throws {
        let json = await Task.detached(priority: .userInitiated) {
            AdBlockList.externalRulesJSON(blocking: domains)
        }.value
        guard activeBlocklistSource == source else { return }
        guard let store = WKContentRuleListStore.default() else { throw BlocklistUpdateError.compileFailed }
        let identifier = AdBlockList.externalIdentifier(forJSON: json)
        var list = await Self.lookUp(identifier, in: store)
        if list == nil {
            list = await Self.compile(identifier, json: json, in: store)
        }
        guard let list else { throw BlocklistUpdateError.compileFailed }
        guard activeBlocklistSource == source else { return }
        externalRuleList = list
        externalDomains = Set(domains)
        externalInfo = info
        await evictStaleCompiledLists()
    }

    // MARK: - Network

    /// One plain GET on an ephemeral session (no cookies, no cache) that rides the browser's proxy.
    private static func fetchList(from url: URL, proxies: [Network.ProxyConfiguration]) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        configuration.proxyConfigurations = proxies
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw BlocklistUpdateError.badStatus(0) }
        guard http.statusCode == 200 else { throw BlocklistUpdateError.badStatus(http.statusCode) }
        guard data.count <= maxBlocklistPayloadBytes else { throw BlocklistUpdateError.payloadTooLarge }
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            throw BlocklistUpdateError.unreadablePayload
        }
        return text
    }

    /// Parsing a 78k-line list is real CPU work — keep it off the main actor.
    private static func parseOffMain(_ text: String) async -> BlocklistParser.Result {
        await Task.detached(priority: .userInitiated) { BlocklistParser.parse(text) }.value
    }

    // MARK: - Storage (Application Support/Blocklists)

    private static func blocklistsDirectory() throws -> URL {
        let directory = try AppEnvironment.supportDirectory().appendingPathComponent("Blocklists", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func domainsFile(for source: BlocklistSource) throws -> URL {
        try blocklistsDirectory().appendingPathComponent("\(source.rawValue).txt")
    }

    private static func infoFile(for source: BlocklistSource) throws -> URL {
        try blocklistsDirectory().appendingPathComponent("\(source.rawValue).json")
    }

    private static func persist(domains: [String], info: BlocklistInfo, for source: BlocklistSource) throws {
        let text = domains.joined(separator: "\n") + "\n"
        try text.write(to: domainsFile(for: source), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try (try encoder.encode(info)).write(to: infoFile(for: source), options: .atomic)
    }

    private static func readInfo(for source: BlocklistSource) -> BlocklistInfo? {
        guard let url = try? infoFile(for: source), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let info = try? decoder.decode(BlocklistInfo.self, from: data), info.source == source else { return nil }
        return info
    }
}
