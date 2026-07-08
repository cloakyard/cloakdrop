import Foundation

/// The per-page aggregation of everything the collector sniffed: raw events go in (`apply`), a
/// ranked, deduped candidate list comes out (`candidates`) — what the browser's media shelf shows.
///
/// Mirrors the extension's per-tab store: items are keyed by `MediaSniffer.recordKey` so a signed
/// CDN URL that rotates its token *overwrites* its earlier sighting (freshest URL wins) instead of
/// duplicating, the store is capped, and everything resets on navigation.
public struct PageMediaState: Sendable {
    /// Cap on distinct recorded items per page — extension parity (60/tab). Overwrites of an
    /// already-recorded key are always allowed; only *new* keys are refused at the cap.
    public static let maxItems = 60

    public private(set) var pageURL: String
    public private(set) var pageTitle: String = ""
    /// The page requested a DRM key system — its media cannot (and must not) be grabbed.
    public private(set) var drmDetected = false
    /// The page assembles media in JS (MediaSource / blob-src players) — a direct sniff may find
    /// nothing even though a video is playing; page extraction is the right offer.
    public private(set) var usesMediaSource = false
    /// Players reported by the top frame's latest page snapshot.
    public private(set) var players: [MediaSniffer.SniffedPlayer] = []

    private var recorded: [String: SniffedItem] = [:]
    private var order: [String] = []

    public init(pageURL: String = "") {
        self.pageURL = pageURL
    }

    /// Distinct recorded items (pre-dedupe) — drives the shelf badge cheaply.
    public var recordedCount: Int { order.count }

    /// Wipe everything for a new page.
    public mutating func reset(pageURL: String) {
        self = PageMediaState(pageURL: pageURL)
    }

    // MARK: - Event intake

    /// Fold one batch of collector events in. Page-level state (title/players/navigation) is only
    /// trusted from the top frame; media sightings are welcome from every frame (iframe players).
    public mutating func apply(_ envelope: SniffEnvelope) {
        for event in envelope.events {
            switch event.kind {
            case .resource:
                guard let url = event.url else { continue }
                record(MediaSniffer.classifyByURL(url))
            case .response:
                guard let url = event.url else { continue }
                let byHeaders = MediaSniffer.classifyByContentType(
                    url,
                    contentType: event.contentType,
                    contentLength: event.contentLength,
                    contentDisposition: event.contentDisposition
                )
                record(byHeaders ?? MediaSniffer.classifyByURL(url))
            case .element:
                applyElement(event)
            case .mse:
                usesMediaSource = true
            case .drm:
                drmDetected = true
            case .page:
                guard envelope.isTopFrame else { continue }
                if let url = event.url, !url.isEmpty { pageURL = url }
                pageTitle = event.title ?? pageTitle
                players = event.players ?? players
                if event.blob == true { usesMediaSource = true }
            case .navigated:
                guard envelope.isTopFrame else { continue }
                reset(pageURL: event.url ?? pageURL)
            }
        }
    }

    private mutating func applyElement(_ event: SniffEvent) {
        guard let url = event.url else { return }
        if event.blob == true || url.hasPrefix("blob:") {
            usesMediaSource = true   // a blob-src player IS MediaSource playback
            return
        }
        // A player's src is media by construction — classify by URL for the noise/segment gates,
        // but fall back to the element's own tag when the URL has no telltale extension
        // (`<video src="/play?id=7">`).
        if let classified = MediaSniffer.classifyByURL(url) {
            record(classified)
        } else if !MediaSniffer.isNoise(url), url.lowercased().hasPrefix("http") {
            record(SniffedItem(url: url, type: event.tag == "audio" ? .audio : .video))
        }
    }

    private mutating func record(_ item: SniffedItem?) {
        guard let item else { return }
        let key = MediaSniffer.recordKey(item.url)
        if recorded[key] != nil {
            recorded[key] = item              // freshest URL/metadata wins, position kept
        } else if order.count < Self.maxItems {
            recorded[key] = item
            order.append(key)
        }
    }

    // MARK: - Output

    /// The shelf's list: everything recorded, run through the dedupe cascade, with the synthetic
    /// "this page's video" extraction item when the page plays via MediaSource and has a player
    /// (extension `pageScan` parity). `dedupeAndRank` suppresses that item again when a direct
    /// stream was sniffed — the stream is the better grab.
    public var candidates: [SniffedItem] {
        var items = order.compactMap { recorded[$0] }
        if let pageItem = pageExtractionItem { items.append(pageItem) }
        return MediaSniffer.dedupeAndRank(items)
    }

    /// The synthetic `.page` item offering yt-dlp extraction of the page itself — present when a
    /// player exists and the page assembles its media in JS (nothing directly sniffable), and never
    /// on a DRM page (extraction would be both futile and wrong).
    public var pageExtractionItem: SniffedItem? {
        guard usesMediaSource, !drmDetected, !pageURL.isEmpty,
              MediaSniffer.primaryPlayerIndex(players) >= 0 else { return nil }
        return SniffedItem(
            url: pageURL,
            type: .page,
            label: pageTitle.isEmpty ? pageURL : pageTitle,
            extract: true
        )
    }
}
