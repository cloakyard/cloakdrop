import Foundation

/// Parses MPEG-DASH manifests (`.mpd`) into a `MediaStream`.
///
/// Walks `MPD → Period → AdaptationSet → Representation`, classifying each adaptation set as video
/// (→ variants), audio, or subtitle (→ tracks), and resolves each representation's segments from
/// whichever addressing mode it uses:
///  - `SegmentTemplate` with a `SegmentTimeline` (`<S t d r>` runs),
///  - `SegmentTemplate` with a fixed `duration` (segment count derived from the period duration),
///  - `SegmentList` (explicit `<SegmentURL>`s), or
///  - a single `BaseURL` file (on-demand, no segmentation).
///
/// `$Number$`/`$Time$`/`$RepresentationID$`/`$Bandwidth$` template variables (with `%0Nd` padding)
/// are expanded, and `BaseURL` is chained across the MPD/Period/AdaptationSet/Representation levels.
/// Pure and I/O-free: handed the fetched `.mpd` bytes and the URL they came from.
public enum DASHParser {
    private enum ContentKind { case video, audio, subtitle }

    /// Upper bound on segments generated per representation. A real stream stays well under this (a
    /// 24-hour VOD at 1-second segments is ~86k); a manifest asking for more — an enormous
    /// `SegmentTimeline` `r` repeat, or a near-zero segment duration — is broken or hostile, so we
    /// stop rather than allocate an unbounded array or trap converting a huge count to `Int`.
    static let maxSegmentsPerRepresentation = 100_000

    public static func parse(_ data: Data, baseURL: URL) throws -> MediaStream {
        guard let document = try? XMLDocument(data: data, options: []),
              let mpd = document.rootElement(), mpd.name == "MPD" else {
            throw MediaParseError.notAPlaylist
        }

        let mpdBase = resolvedBaseURL(mpd, baseURL)
        let presentationDuration = parseISO8601Duration(mpd.attribute(forName: "mediaPresentationDuration")?.stringValue)

        var variants: [MediaVariant] = []
        var audioTracks: [MediaTrack] = []
        var subtitleTracks: [MediaTrack] = []

        for period in mpd.elements(forName: "Period") {
            let periodBase = resolvedBaseURL(period, mpdBase)
            let periodDuration = parseISO8601Duration(period.attribute(forName: "duration")?.stringValue) ?? presentationDuration

            for adaptationSet in period.elements(forName: "AdaptationSet") {
                let setBase = resolvedBaseURL(adaptationSet, periodBase)
                for representation in adaptationSet.elements(forName: "Representation") {
                    let kind = classify(adaptationSet, representation)
                    let resolved = buildRepresentation(
                        representation,
                        adaptationSet: adaptationSet,
                        base: resolvedBaseURL(representation, setBase),
                        periodDuration: periodDuration
                    )
                    guard !resolved.segments.isEmpty else { continue }
                    append(kind, representation, adaptationSet, resolved, into: &variants, &audioTracks, &subtitleTracks)
                }
            }
        }

        guard !variants.isEmpty || !audioTracks.isEmpty else { throw MediaParseError.noContent }
        return MediaStream(
            sourceURL: baseURL,
            format: .dash,
            variants: variants,
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks
        )
    }

    // MARK: Assembling model objects

    private static func append(
        _ kind: ContentKind,
        _ representation: XMLElement,
        _ adaptationSet: XMLElement,
        _ resolved: (segments: [MediaSegment], initSegment: MediaInitSegment?),
        into variants: inout [MediaVariant],
        _ audioTracks: inout [MediaTrack],
        _ subtitleTracks: inout [MediaTrack]
    ) {
        let id = representation.attribute(forName: "id")?.stringValue ?? "\(variants.count + audioTracks.count)"
        let language = adaptationSet.attribute(forName: "lang")?.stringValue
        switch kind {
        case .video:
            variants.append(MediaVariant(
                id: id,
                bandwidth: intAttr(representation, "bandwidth") ?? 0,
                resolution: resolution(representation, adaptationSet),
                codecs: codecs(representation, adaptationSet),
                frameRate: frameRate(representation, adaptationSet),
                initSegment: resolved.initSegment,
                segments: resolved.segments
            ))
        case .audio:
            audioTracks.append(MediaTrack(
                id: id, kind: .audio, groupID: adaptationSet.attribute(forName: "id")?.stringValue,
                language: language, initSegment: resolved.initSegment, segments: resolved.segments
            ))
        case .subtitle:
            subtitleTracks.append(MediaTrack(
                id: id, kind: .subtitle, groupID: adaptationSet.attribute(forName: "id")?.stringValue,
                language: language, initSegment: resolved.initSegment, segments: resolved.segments
            ))
        }
    }

    private static func classify(_ adaptationSet: XMLElement, _ representation: XMLElement) -> ContentKind {
        let type = (adaptationSet.attribute(forName: "contentType")?.stringValue ?? "").lowercased()
        let mime = (representation.attribute(forName: "mimeType")?.stringValue
            ?? adaptationSet.attribute(forName: "mimeType")?.stringValue ?? "").lowercased()
        if type == "video" || mime.hasPrefix("video/") { return .video }
        if type == "audio" || mime.hasPrefix("audio/") { return .audio }
        if type == "text" || mime.hasPrefix("text/") || mime.contains("ttml") || mime.contains("vtt") { return .subtitle }
        return (intAttr(representation, "width") ?? intAttr(adaptationSet, "width")) != nil ? .video : .audio
    }

    // MARK: Segment resolution

    private static func buildRepresentation(
        _ representation: XMLElement,
        adaptationSet: XMLElement,
        base: URL,
        periodDuration: Double?
    ) -> (segments: [MediaSegment], initSegment: MediaInitSegment?) {
        let repID = representation.attribute(forName: "id")?.stringValue ?? ""
        let bandwidth = intAttr(representation, "bandwidth") ?? 0

        if let template = firstChild(representation, adaptationSet, "SegmentTemplate") {
            return fromTemplate(template, base: base, repID: repID, bandwidth: bandwidth, periodDuration: periodDuration)
        }
        if let list = firstChild(representation, adaptationSet, "SegmentList") {
            return fromList(list, base: base)
        }
        // Single-file (on-demand) representation: the BaseURL is the whole media.
        return ([MediaSegment(id: 0, url: base, duration: periodDuration ?? 0)], nil)
    }

    private static func fromTemplate(
        _ template: XMLElement,
        base: URL,
        repID: String,
        bandwidth: Int,
        periodDuration: Double?
    ) -> (segments: [MediaSegment], initSegment: MediaInitSegment?) {
        let media = template.attribute(forName: "media")?.stringValue ?? ""
        let timescale = Double(intAttr(template, "timescale") ?? 1)
        let startNumber = intAttr(template, "startNumber") ?? 1

        let initSegment = (template.attribute(forName: "initialization")?.stringValue).flatMap { initTemplate -> MediaInitSegment? in
            let expanded = expand(initTemplate, repID: repID, bandwidth: bandwidth, number: nil, time: nil)
            return resolve(expanded, base).map { MediaInitSegment(url: $0) }
        }

        var segments: [MediaSegment] = []
        if let timeline = template.elements(forName: "SegmentTimeline").first {
            var number = startNumber
            var time: Int64 = 0
            var index = 0
            build: for segmentRun in timeline.elements(forName: "S") {
                if let explicit = int64Attr(segmentRun, "t") { time = explicit }
                let duration = int64Attr(segmentRun, "d") ?? 0
                let repeatCount = intAttr(segmentRun, "r") ?? 0
                for _ in 0...max(0, repeatCount) {
                    if segments.count >= Self.maxSegmentsPerRepresentation { break build }
                    let url = expand(media, repID: repID, bandwidth: bandwidth, number: number, time: time)
                    if let resolved = resolve(url, base) {
                        segments.append(MediaSegment(id: index, url: resolved, duration: Double(duration) / timescale))
                        index += 1
                    }
                    number += 1
                    time += duration
                }
            }
        } else if let duration = int64Attr(template, "duration"), duration > 0, let periodDuration {
            let segmentSeconds = Double(duration) / timescale
            guard segmentSeconds > 0 else { return (segments, initSegment) }
            // Clamp before converting to Int: a near-zero segment duration yields a huge (or
            // non-finite) count that would otherwise trap in `Int(_:)` or allocate unbounded.
            let rawCount = (periodDuration / segmentSeconds).rounded(.up)
            guard rawCount.isFinite, rawCount > 0 else { return (segments, initSegment) }
            let count = Int(min(rawCount, Double(Self.maxSegmentsPerRepresentation)))
            for index in 0..<count {
                let number = startNumber + index
                let time = Int64(index) * duration
                let url = expand(media, repID: repID, bandwidth: bandwidth, number: number, time: time)
                if let resolved = resolve(url, base) {
                    segments.append(MediaSegment(id: index, url: resolved, duration: segmentSeconds))
                }
            }
        }
        return (segments, initSegment)
    }

    private static func fromList(
        _ list: XMLElement,
        base: URL
    ) -> (segments: [MediaSegment], initSegment: MediaInitSegment?) {
        let timescale = Double(intAttr(list, "timescale") ?? 1)
        let duration = Double(int64Attr(list, "duration") ?? 0) / timescale
        let initSegment = list.elements(forName: "Initialization").first?
            .attribute(forName: "sourceURL")?.stringValue
            .flatMap { resolve($0, base) }
            .map { MediaInitSegment(url: $0) }

        var segments: [MediaSegment] = []
        for (index, segmentURL) in list.elements(forName: "SegmentURL").enumerated() {
            guard let media = segmentURL.attribute(forName: "media")?.stringValue, let url = resolve(media, base) else { continue }
            segments.append(MediaSegment(id: index, url: url, duration: duration))
        }
        return (segments, initSegment)
    }

    // MARK: Template variables

    /// The DASH template-variable pattern, compiled once. Hoisted to a static so expanding a
    /// manifest with tens of thousands of segments doesn't reconstruct the matcher per segment.
    /// `nonisolated(unsafe)` is sound: a compiled `Regex` is immutable and its matching is
    /// read-only, so sharing it across threads has no mutable state to guard.
    nonisolated(unsafe) private static let templateVariablePattern =
        /\$(RepresentationID|Number|Bandwidth|Time)(%0\d+[dxX])?\$/

    /// Expand `$RepresentationID$`, `$Number$`, `$Bandwidth$`, `$Time$` (with optional `%0Nd`
    /// padding). `$$` is a literal `$`.
    static func expand(_ template: String, repID: String, bandwidth: Int, number: Int?, time: Int64?) -> String {
        let escaped = template.replacingOccurrences(of: "$$", with: "\u{0}")
        let expanded = escaped.replacing(Self.templateVariablePattern) { match in
            let name = String(match.output.1)
            let format = match.output.2.map(String.init)
            switch name {
            case "RepresentationID": return repID
            case "Bandwidth": return formatted(bandwidth, format)
            case "Number": return formatted(number ?? 0, format)
            case "Time": return formatted(Int(time ?? 0), format)
            default: return ""
            }
        }
        return expanded.replacingOccurrences(of: "\u{0}", with: "$")
    }

    private static func formatted(_ value: Int, _ format: String?) -> String {
        guard let format else { return "\(value)" }
        return String(format: format, value)
    }

    // MARK: Attribute & element helpers

    private static func resolution(_ representation: XMLElement, _ adaptationSet: XMLElement) -> MediaResolution? {
        guard let width = intAttr(representation, "width") ?? intAttr(adaptationSet, "width"),
              let height = intAttr(representation, "height") ?? intAttr(adaptationSet, "height") else { return nil }
        return MediaResolution(width: width, height: height)
    }

    private static func codecs(_ representation: XMLElement, _ adaptationSet: XMLElement) -> [String] {
        guard let raw = representation.attribute(forName: "codecs")?.stringValue
            ?? adaptationSet.attribute(forName: "codecs")?.stringValue else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func frameRate(_ representation: XMLElement, _ adaptationSet: XMLElement) -> Double? {
        guard let raw = representation.attribute(forName: "frameRate")?.stringValue
            ?? adaptationSet.attribute(forName: "frameRate")?.stringValue else { return nil }
        // frameRate may be "30" or a ratio "30000/1001".
        if let slash = raw.firstIndex(of: "/") {
            let numerator = Double(raw[..<slash]) ?? 0
            let denominator = Double(raw[raw.index(after: slash)...]) ?? 1
            return denominator == 0 ? nil : numerator / denominator
        }
        return Double(raw)
    }

    /// The named child of the representation, falling back to the adaptation set's (DASH inheritance).
    private static func firstChild(_ representation: XMLElement, _ adaptationSet: XMLElement, _ name: String) -> XMLElement? {
        representation.elements(forName: name).first ?? adaptationSet.elements(forName: name).first
    }

    private static func resolvedBaseURL(_ element: XMLElement, _ parent: URL) -> URL {
        guard let text = element.elements(forName: "BaseURL").first?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let url = URL(string: text, relativeTo: parent)?.absoluteURL else { return parent }
        return url
    }

    private static func resolve(_ uri: String, _ base: URL) -> URL? {
        URL(string: uri, relativeTo: base)?.absoluteURL
    }

    private static func intAttr(_ element: XMLElement, _ name: String) -> Int? {
        element.attribute(forName: name)?.stringValue.flatMap { Int($0) }
    }

    private static func int64Attr(_ element: XMLElement, _ name: String) -> Int64? {
        element.attribute(forName: name)?.stringValue.flatMap { Int64($0) }
    }

    /// Compiled once and shared read-only (see `templateVariablePattern` for the safety note).
    nonisolated(unsafe) private static let iso8601DurationPattern =
        /P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:([\d.]+)S)?)?/

    /// Parse an ISO 8601 duration (`PnDTnHnMnS`, e.g. `PT1H2M3.5S`) into seconds. Years/months are
    /// ignored — media durations don't use them.
    static func parseISO8601Duration(_ raw: String?) -> Double? {
        guard let raw, raw.hasPrefix("P") else { return nil }
        guard let match = try? Self.iso8601DurationPattern.wholeMatch(in: raw) else { return nil }
        let days = match.output.1.flatMap { Double($0) } ?? 0
        let hours = match.output.2.flatMap { Double($0) } ?? 0
        let minutes = match.output.3.flatMap { Double($0) } ?? 0
        let seconds = match.output.4.flatMap { Double($0) } ?? 0
        let total = days * 86_400 + hours * 3_600 + minutes * 60 + seconds
        return total > 0 ? total : nil
    }
}
