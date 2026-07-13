import Foundation

/// One batch of raw sightings from the collector script (`MediaSniffer.js`) running inside a web
/// page — the wire format between the injected JS and the app. The JS is a dumb reporter; every
/// classification decision happens on this side (in `MediaSniffer`/`PageMediaState`), where it's
/// unit-tested.
public struct SniffEnvelope: Sendable {
    /// Wire-format version (the JS sends `v: 1`).
    public var version: Int
    /// The URL of the frame that reported (subframes sniff too — `all frames` parity).
    public var frameURL: String
    /// Whether the reporting frame is the top frame — page-level state (title, players,
    /// navigation resets) is only trusted from the top frame.
    public var isTopFrame: Bool
    public var events: [SniffEvent]

    public init(version: Int = 1, frameURL: String, isTopFrame: Bool, events: [SniffEvent]) {
        self.version = version
        self.frameURL = frameURL
        self.isTopFrame = isTopFrame
        self.events = events
    }
}

/// A single raw sighting. One flat struct for every kind — the collector sends only the fields a
/// kind uses, and decoding is lenient so a malformed event never poisons its batch.
public struct SniffEvent: Sendable {
    public enum Kind: String, Sendable, Codable {
        /// A resource URL from `PerformanceObserver` — URL only (the catch-all channel; also sees
        /// service-worker-served media).
        case resource
        /// A response observed by the `fetch`/XHR hooks — URL plus whatever headers CORS exposed.
        case response
        /// A `<video>`/`<audio>` (or `<source>`) src. `blob: true` marks MediaSource playback —
        /// nothing downloadable at that URL, but a strong "use page extraction" signal.
        case element
        /// `MediaSource.addSourceBuffer` fired — the page assembles its media in JS.
        case mse
        /// DRM actually engaged — `setMediaKeys(non-nil)` on a player, or an `encrypted` media
        /// event (the stream carries encrypted init data). Deliberately NOT the
        /// `requestMediaKeySystemAccess` capability probe, which players run on clear content too.
        case drm
        /// A page snapshot: URL, title, and every player's kind/on-screen area (for the
        /// primary-player pick). Sent by the top frame only, repeated as the page changes.
        case page
        /// The page navigated in place (history API, URL change sans fragment) — reset state.
        case navigated
    }

    public var kind: Kind
    public var url: String?
    public var initiator: String?
    public var size: Int64?
    public var contentType: String?
    public var contentLength: Int64?
    public var contentDisposition: String?
    public var tag: String?
    public var duration: Double?
    public var blob: Bool?
    public var mime: String?
    public var keySystem: String?
    public var title: String?
    public var players: [MediaSniffer.SniffedPlayer]?

    public init(
        kind: Kind,
        url: String? = nil,
        initiator: String? = nil,
        size: Int64? = nil,
        contentType: String? = nil,
        contentLength: Int64? = nil,
        contentDisposition: String? = nil,
        tag: String? = nil,
        duration: Double? = nil,
        blob: Bool? = nil,
        mime: String? = nil,
        keySystem: String? = nil,
        title: String? = nil,
        players: [MediaSniffer.SniffedPlayer]? = nil
    ) {
        self.kind = kind
        self.url = url
        self.initiator = initiator
        self.size = size
        self.contentType = contentType
        self.contentLength = contentLength
        self.contentDisposition = contentDisposition
        self.tag = tag
        self.duration = duration
        self.blob = blob
        self.mime = mime
        self.keySystem = keySystem
        self.title = title
        self.players = players
    }
}

extension SniffEvent: Codable {}

extension SniffEnvelope: Codable {
    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case frameURL = "frame"
        case isTopFrame = "top"
        case events
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        frameURL = try container.decodeIfPresent(String.self, forKey: .frameURL) ?? ""
        isTopFrame = try container.decodeIfPresent(Bool.self, forKey: .isTopFrame) ?? false
        // Lenient per-event decoding: an unknown kind or malformed field drops that event, never
        // the batch (the collector runs inside arbitrary pages — hostile input is the baseline).
        var events: [SniffEvent] = []
        if var list = try? container.nestedUnkeyedContainer(forKey: .events) {
            while !list.isAtEnd {
                if let event = try? list.decode(SniffEvent.self) {
                    events.append(event)
                } else if (try? list.decode(AnyIgnored.self)) == nil {
                    break   // the skip itself failed — the container can't advance, so bail
                }
            }
        }
        self.events = events
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(frameURL, forKey: .frameURL)
        try container.encode(isTopFrame, forKey: .isTopFrame)
        try container.encode(events, forKey: .events)
    }

    /// Decode the body a `WKScriptMessage` delivers (an `NSDictionary` tree). Returns `nil` for
    /// anything that isn't a valid envelope — the page can post arbitrary junk at the handler.
    public static func parse(messageBody: Any) -> SniffEnvelope? {
        guard JSONSerialization.isValidJSONObject(messageBody),
              let data = try? JSONSerialization.data(withJSONObject: messageBody),
              data.count <= 1_048_576,   // a batch is a few KB; a megabyte is an attack, not a batch
              let envelope = try? JSONDecoder().decode(SniffEnvelope.self, from: data) else { return nil }
        return envelope
    }
}

/// Decodes (and discards) any JSON value — used to skip malformed array elements.
private struct AnyIgnored: Decodable {
    init(from decoder: any Decoder) throws {
        if let container = try? decoder.container(keyedBy: FreeformKey.self) {
            for key in container.allKeys { _ = try? container.decode(AnyIgnored.self, forKey: key) }
        } else if var list = try? decoder.unkeyedContainer() {
            while !list.isAtEnd { _ = try? list.decode(AnyIgnored.self) }
        } else {
            let single = try decoder.singleValueContainer()
            if single.decodeNil() { return }
            if (try? single.decode(Bool.self)) != nil { return }
            if (try? single.decode(Double.self)) != nil { return }
            _ = try? single.decode(String.self)
        }
    }

    private struct FreeformKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
