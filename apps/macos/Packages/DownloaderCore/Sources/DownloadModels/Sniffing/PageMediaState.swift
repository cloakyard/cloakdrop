import Foundation

/// The per-page aggregation of everything the collector sniffed: raw events go in (`apply`), a
/// ranked, deduped candidate list comes out (`candidates`) — what the browser's media shelf shows.
///
/// The in-app browser's per-tab store: items are keyed by `MediaSniffer.recordKey` so a signed
/// CDN URL that rotates its token *overwrites* its earlier sighting (freshest URL wins) instead of
/// duplicating, the store is capped, and everything resets on navigation.
public struct PageMediaState: Sendable {
    /// Cap on distinct recorded items per page — original sniffer parity (60/tab). Overwrites of an
    /// already-recorded key are always allowed; only *new* keys are refused at the cap.
    public static let maxItems = 60

    public private(set) var pageURL: String
    public private(set) var pageTitle: String = ""
    /// Players reported by the top frame's latest page snapshot.
    public private(set) var players: [MediaSniffer.SniffedPlayer] = []

    private enum Evidence: Int, Sendable {
        case resource = 1
        case response = 2
        case element = 3
        case attachment = 4
    }

    private struct Observation: Sendable {
        var item: SniffedItem
        var frameKey: String
        var isTopFrame: Bool
        var evidence: Evidence
        var byteCount: Int64
        var duration: Double
        var area: Double
        var sequence: Int
    }

    private struct FrameActivity: Sendable {
        var isTopFrame = false
        var players: [MediaSniffer.SniffedPlayer] = []
        var sawMediaElement = false
        var usesMediaSource = false
        var drmDetected = false
        var sequence = 0

        var largestPlayerArea: Double { players.map(\.area).max() ?? 0 }
        var isPlayable: Bool { !players.isEmpty || sawMediaElement || usesMediaSource || drmDetected }
    }

    private struct CandidateScore: Comparable {
        var priority: Int
        var byteCount: Int64
        var duration: Double
        var area: Double
        var sequence: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            if lhs.area != rhs.area { return lhs.area < rhs.area }
            if lhs.duration != rhs.duration { return lhs.duration < rhs.duration }
            if lhs.byteCount != rhs.byteCount { return lhs.byteCount < rhs.byteCount }
            return lhs.sequence < rhs.sequence
        }
    }

    private var recorded: [String: Observation] = [:]
    private var order: [String] = []
    private var frames: [String: FrameActivity] = [:]
    private var eventSequence = 0

    public init(pageURL: String = "") {
        self.pageURL = pageURL
    }

    /// Distinct recorded items (pre-dedupe) — drives the shelf badge cheaply.
    public var recordedCount: Int { order.count }

    /// DRM and MediaSource are frame-scoped. Ad iframes routinely probe or instantiate their own
    /// players; only the frame selected as the page's primary player is allowed to affect the shelf.
    public var drmDetected: Bool {
        guard let key = primaryMediaFrameKey else {
            return frames.values.contains { $0.isTopFrame && $0.drmDetected }
        }
        return frames[key]?.drmDetected == true
    }

    public var usesMediaSource: Bool {
        guard let key = primaryMediaFrameKey else {
            return frames.values.contains { $0.isTopFrame && $0.usesMediaSource }
        }
        return frames[key]?.usesMediaSource == true
    }

    /// Wipe everything for a new page.
    public mutating func reset(pageURL: String) {
        self = PageMediaState(pageURL: pageURL)
    }

    // MARK: - Event intake

    /// Fold one batch of collector events in. Page-level state (title/players/navigation) is only
    /// trusted from the top frame; media sightings are welcome from every frame (iframe players).
    public mutating func apply(_ envelope: SniffEnvelope) {
        for event in envelope.events {
            eventSequence += 1
            switch event.kind {
            case .resource:
                guard let url = event.url else { continue }
                record(
                    MediaSniffer.classifyByURL(url, contentLength: event.size),
                    envelope: envelope,
                    evidence: .resource,
                    byteCount: event.size
                )
            case .response:
                guard let url = event.url else { continue }
                let attachment = MediaSniffer.attachmentFilename(event.contentDisposition) != nil
                let byHeaders = MediaSniffer.classifyByContentType(
                    url,
                    contentType: event.contentType,
                    contentLength: event.contentLength,
                    contentDisposition: event.contentDisposition
                )
                record(
                    byHeaders ?? MediaSniffer.classifyByURL(url, contentLength: event.contentLength),
                    envelope: envelope,
                    evidence: attachment ? .attachment : .response,
                    byteCount: event.contentLength
                )
            case .element:
                updateFrame(envelope) { $0.sawMediaElement = true }
                applyElement(event, envelope: envelope)
            case .mse:
                updateFrame(envelope) { $0.usesMediaSource = true }
            case .drm:
                updateFrame(envelope) { $0.drmDetected = true }
            case .page:
                updateFrame(envelope, eventURL: event.url) { activity in
                    activity.players = event.players ?? activity.players
                    if event.blob == true { activity.usesMediaSource = true }
                }
                if envelope.isTopFrame {
                    if let url = event.url, !url.isEmpty { pageURL = url }
                    pageTitle = event.title ?? pageTitle
                    players = event.players ?? players
                }
            case .navigated:
                guard envelope.isTopFrame else { continue }
                reset(pageURL: event.url ?? pageURL)
            }
        }
    }

    private mutating func applyElement(_ event: SniffEvent, envelope: SniffEnvelope) {
        guard let url = event.url else { return }
        if event.blob == true || url.hasPrefix("blob:") {
            updateFrame(envelope) { $0.usesMediaSource = true }   // a blob-src player IS MediaSource playback
            return
        }
        // A player's src is media by construction — classify by URL for the noise/segment gates,
        // but fall back to the element's own tag when the URL has no telltale extension
        // (`<video src="/play?id=7">`).
        if let classified = MediaSniffer.classifyByURL(url) {
            record(
                classified, envelope: envelope, evidence: .element,
                duration: event.duration, area: event.area
            )
        } else if !MediaSniffer.isNoise(url), url.lowercased().hasPrefix("http") {
            record(
                SniffedItem(url: url, type: event.tag == "audio" ? .audio : .video),
                envelope: envelope,
                evidence: .element,
                duration: event.duration,
                area: event.area
            )
        }
    }

    private mutating func record(
        _ item: SniffedItem?,
        envelope: SniffEnvelope,
        evidence: Evidence,
        byteCount: Int64? = nil,
        duration: Double? = nil,
        area: Double? = nil
    ) {
        guard let item else { return }
        let key = MediaSniffer.recordKey(item.url)
        let frame = Self.frameKey(envelope.frameURL.isEmpty && envelope.isTopFrame ? pageURL : envelope.frameURL)
        let observation = Observation(
            item: item,
            frameKey: frame,
            isTopFrame: envelope.isTopFrame,
            evidence: evidence,
            byteCount: max(0, byteCount ?? 0),
            duration: max(0, duration ?? 0),
            area: max(0, area ?? 0),
            sequence: eventSequence
        )
        if let previous = recorded[key] {
            // Fresh signed URL/frame wins, while stronger metadata from an earlier response/element
            // is retained. The position remains stable.
            recorded[key] = Observation(
                item: item,
                frameKey: frame,
                isTopFrame: envelope.isTopFrame,
                evidence: previous.evidence.rawValue > evidence.rawValue ? previous.evidence : evidence,
                byteCount: max(previous.byteCount, observation.byteCount),
                duration: max(previous.duration, observation.duration),
                area: max(previous.area, observation.area),
                sequence: eventSequence
            )
        } else if order.count < Self.maxItems {
            recorded[key] = observation
            order.append(key)
        }
    }

    private mutating func updateFrame(
        _ envelope: SniffEnvelope,
        eventURL: String? = nil,
        update: (inout FrameActivity) -> Void
    ) {
        let raw = eventURL.flatMap { $0.isEmpty ? nil : $0 }
            ?? (envelope.frameURL.isEmpty && envelope.isTopFrame ? pageURL : envelope.frameURL)
        let key = Self.frameKey(raw)
        var activity = frames[key] ?? FrameActivity()
        activity.isTopFrame = activity.isTopFrame || envelope.isTopFrame
        activity.sequence = eventSequence
        update(&activity)
        frames[key] = activity
    }

    // MARK: - Output

    /// The shelf deliberately exposes one primary grab. Popular supported sites route through the
    /// page extractor (which resolves the authored video rather than an ad/player resource). Generic
    /// pages are scoped to the largest active player frame, deduped, and reduced to one best item.
    /// A click therefore cannot accidentally enqueue a wall of renditions or an ad iframe's video.
    public var candidates: [SniffedItem] {
        let recognizedPage = recognizedVideoPage
        if let recognizedPage, !recognizedPage.prefersObservedMedia {
            return pageExtractionItem.map { [$0] } ?? []
        }

        var observations = order.compactMap { recorded[$0] }
        if let primary = primaryMediaFrameKey {
            let scoped = observations.filter { $0.frameKey == primary }
            // Do not let a noisy but not-yet-inventoried iframe blank a valid top-frame grab. Once
            // the primary player has candidates, though, every other frame is irrelevant.
            if !scoped.isEmpty { observations = scoped }
        }

        var items = MediaSniffer.dedupeAndRank(observations.map(\.item))
        if drmDetected {
            items.removeAll { $0.type != .file }   // protected media is never offered; plain downloads remain valid
        }
        let streamCount = items.count { $0.type == .stream }
        if recognizedPage?.prefersObservedMedia != true,
           streamCount > 1, primaryFrameHasPlayerActivity, let pageItem = pageExtractionItem {
            // Several unrelated media URLs survived every deterministic collapse pass. Asking the
            // extractor for the page is safer than guessing whether the last one was a post-roll.
            return [pageItem]
        }
        if let selected = selectPrimary(from: items, observations: observations) { return [selected] }
        return pageExtractionItem.map { [$0] } ?? []
    }

    /// The synthetic `.page` item offering yt-dlp extraction of the page itself — present when a
    /// player exists (including a JS/MediaSource player with nothing directly sniffable), and never
    /// on a DRM page (extraction would be both futile and wrong). A plain direct candidate still wins
    /// in `candidates`; this item is the safe fallback for an empty or ambiguous player.
    public var pageExtractionItem: SniffedItem? {
        guard !drmDetected, !pageURL.isEmpty else { return nil }
        let knownPage = recognizedVideoPage
        let observedMedia = primaryMediaFrameKey != nil
        if knownPage?.requiresObservedMedia == true, !observedMedia { return nil }
        guard knownPage != nil || primaryFrameHasPlayerActivity else { return nil }
        return SniffedItem(
            url: pageURL,
            type: .page,
            label: pageTitle.isEmpty ? pageURL : pageTitle,
            extract: true
        )
    }

    private var recognizedVideoPage: VideoPageSite? {
        URL(string: pageURL).flatMap(VideoPageDetector.detect)
    }

    /// The largest visible player frame wins. This keeps a 1280×720 embedded player and ignores a
    /// 300×250 ad iframe even when both load plausible `.m3u8` URLs. Ties prefer the top frame, then
    /// the most recently active one. With no player inventory yet, use the frame carrying the
    /// strongest/latest candidate evidence as a temporary best effort.
    private var primaryMediaFrameKey: String? {
        let playable = frames.filter { $0.value.isPlayable }
        if !playable.isEmpty {
            return playable.max { lhs, rhs in
                if lhs.value.largestPlayerArea != rhs.value.largestPlayerArea {
                    return lhs.value.largestPlayerArea < rhs.value.largestPlayerArea
                }
                if lhs.value.isTopFrame != rhs.value.isTopFrame { return !lhs.value.isTopFrame }
                return lhs.value.sequence < rhs.value.sequence
            }?.key
        }
        return recorded.values.max { lhs, rhs in
            if lhs.evidence.rawValue != rhs.evidence.rawValue { return lhs.evidence.rawValue < rhs.evidence.rawValue }
            if lhs.isTopFrame != rhs.isTopFrame { return !lhs.isTopFrame }
            return lhs.sequence < rhs.sequence
        }?.frameKey
    }

    private var primaryFrameHasPlayerActivity: Bool {
        guard let key = primaryMediaFrameKey else { return false }
        return frames[key]?.isPlayable == true
    }

    private func selectPrimary(from items: [SniffedItem], observations: [Observation]) -> SniffedItem? {
        guard !items.isEmpty else { return nil }
        let byKey = Dictionary(observations.map { (MediaSniffer.recordKey($0.item.url), $0) }, uniquingKeysWith: { _, new in new })
        // `Content-Disposition: attachment` is a direct user/server download decision, not a passive
        // page asset. It must beat a decorative/promo media resource on download portals.
        let attachments = items.filter { byKey[MediaSniffer.recordKey($0.url)]?.evidence == .attachment }
        if let attachment = attachments.max(by: {
            let lhs = byKey[MediaSniffer.recordKey($0.url)]
            let rhs = byKey[MediaSniffer.recordKey($1.url)]
            if lhs?.byteCount != rhs?.byteCount { return (lhs?.byteCount ?? 0) < (rhs?.byteCount ?? 0) }
            return (lhs?.sequence ?? 0) < (rhs?.sequence ?? 0)
        }) { return attachment }
        func score(_ item: SniffedItem) -> CandidateScore {
            let observation = byKey[MediaSniffer.recordKey(item.url)]
            let typeRank: Int = switch item.type {
            case .page: 500
            case .stream: 400
            case .video: 300
            case .audio: 200
            case .file: 100
            }
            return CandidateScore(
                priority: typeRank + (observation?.evidence.rawValue ?? 0) * 10,
                byteCount: observation?.byteCount ?? 0,
                duration: observation?.duration ?? 0,
                area: observation?.area ?? 0,
                sequence: observation?.sequence ?? 0
            )
        }
        return items.max { lhs, rhs in
            score(lhs) < score(rhs)   // pre-roll is normally observed before the authored program
        }
    }

    private static func frameKey(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return raw }
        components.fragment = nil
        return components.string ?? raw
    }
}
