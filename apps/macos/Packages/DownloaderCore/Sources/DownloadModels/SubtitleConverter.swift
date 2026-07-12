import Foundation

/// Turns the subtitle text a media grab fetches (WebVTT — HLS/DASH/yt-dlp's usual output — or SRT)
/// into a clean SubRip (`.srt`) sidecar. Pure and I/O-free so it's exercised by the fast `swift test`
/// loop against literal fixtures; the engine calls it at finalize with the concatenated cue text.
///
/// WebVTT and SRT are nearly the same line-based cue format, differing in a header, a `.`-vs-`,`
/// millisecond separator, HTML-ish inline tags, and cue-positioning settings. We parse WebVTT into a
/// neutral cue list (honoring HLS's `X-TIMESTAMP-MAP` offset so segmented captions line up) and
/// re-emit SRT, which every player and Quick Look reads as a sidecar.
public enum SubtitleConverter {
    /// One caption: a time window and its (tag-stripped) text.
    public struct Cue: Sendable, Hashable {
        public var start: Double      // seconds
        public var end: Double        // seconds
        public var text: String
        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    /// Convert one subtitle document to SRT. Already-SRT input is normalized (renumbered, timings
    /// cleaned) and passed through; WebVTT is parsed and re-emitted. Returns `nil` when no cue with
    /// text can be recovered, so the caller writes no empty sidecar.
    public static func toSRT(_ text: String) -> String? {
        let cues = parseCues(text)
        return srt(from: cues)
    }

    /// Convert a sequence of subtitle segments (HLS delivers WebVTT as many small files, each with its
    /// own `X-TIMESTAMP-MAP`) into a single SRT, concatenating and re-sorting their cues and dropping
    /// duplicates that overlap segment boundaries. Returns `nil` when nothing usable remains.
    public static func segmentsToSRT(_ segments: [String]) -> String? {
        var all: [Cue] = []
        for segment in segments { all.append(contentsOf: parseCues(segment)) }
        all.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        // Drop exact adjacent duplicates (a cue repeated across two segments' overlap).
        var deduped: [Cue] = []
        for cue in all where deduped.last != cue { deduped.append(cue) }
        return srt(from: deduped)
    }

    // MARK: - Parsing

    /// Parse WebVTT (or SRT) into cues. Skips `WEBVTT`/`NOTE`/`STYLE`/`REGION` blocks, applies the
    /// `X-TIMESTAMP-MAP` offset when present, strips inline tags and cue settings, and tolerates both
    /// `.`- and `,`-separated milliseconds and hour-less timestamps.
    static func parseCues(_ text: String) -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let offset = timestampMapOffset(normalized)
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let upper = trimmed.uppercased()
            if upper.hasPrefix("WEBVTT") || upper.hasPrefix("NOTE") || upper.hasPrefix("STYLE") || upper.hasPrefix("REGION") {
                continue
            }
            var lines = trimmed.components(separatedBy: "\n")
            // An optional cue identifier precedes the timing line — drop it (SRT renumbers).
            if let first = lines.first, !first.contains("-->") { lines.removeFirst() }
            guard let timingLine = lines.first, timingLine.contains("-->"),
                  let (start, end) = parseTiming(timingLine) else { continue }
            let body = lines.dropFirst().joined(separator: "\n")
            let clean = stripTags(body).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            cues.append(Cue(start: start + offset, end: end + offset, text: clean))
        }
        return cues
    }

    /// The seconds to add to every cue so a segment's local times map onto the presentation timeline:
    /// `(MPEGTS / 90000) - LOCAL`. Absent/zero when there's no `X-TIMESTAMP-MAP` (VOD single files).
    private static func timestampMapOffset(_ text: String) -> Double {
        guard let range = text.range(of: "X-TIMESTAMP-MAP=", options: .caseInsensitive) else { return 0 }
        let line = text[range.upperBound...].prefix { $0 != "\n" }
        var mpegts = 0.0, local = 0.0
        for part in line.split(separator: ",") {
            let kv = part.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces).uppercased()
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            if key == "MPEGTS" {
                mpegts = (Double(value) ?? 0) / 90_000
            } else if key == "LOCAL" {
                local = parseTimestamp(value) ?? 0
            }
        }
        return mpegts - local
    }

    /// Parse a `start --> end [settings]` line into seconds, ignoring any cue-position settings after
    /// the end timestamp.
    private static func parseTiming(_ line: String) -> (Double, Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        let startText = parts[0].trimmingCharacters(in: .whitespaces)
        // The end timestamp is the first whitespace-delimited token after `-->` (settings follow it).
        let endText = parts[1].trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard let start = parseTimestamp(startText), let end = parseTimestamp(endText) else { return nil }
        return (start, end)
    }

    /// Parse `HH:MM:SS.mmm`, `MM:SS.mmm`, or the `,`-separated SRT variant into seconds.
    static func parseTimestamp(_ text: String) -> Double? {
        let unified = text.replacingOccurrences(of: ",", with: ".")
        let components = unified.split(separator: ":")
        guard (2...3).contains(components.count) else { return nil }
        var seconds = 0.0
        for component in components {
            guard let value = Double(component) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    /// Strip WebVTT inline markup: voice/class spans (`<v Bob>`, `<c.loud>`), closing tags, and
    /// mid-cue timestamp tags (`<00:00:01.000>`), then decode the handful of entities WebVTT escapes.
    private static func stripTags(_ text: String) -> String {
        var result = ""
        var insideTag = false
        for character in text {
            if character == "<" { insideTag = true; continue }
            if character == ">" { insideTag = false; continue }
            if !insideTag { result.append(character) }
        }
        return result
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    // MARK: - Emitting

    /// Render cues as SRT — 1-based index, `HH:MM:SS,mmm` timings, blank line between. `nil` for none.
    static func srt(from cues: [SubtitleConverter.Cue]) -> String? {
        guard !cues.isEmpty else { return nil }
        var out = ""
        for (index, cue) in cues.enumerated() {
            out += "\(index + 1)\n"
            out += "\(srtTimestamp(cue.start)) --> \(srtTimestamp(cue.end))\n"
            out += "\(cue.text)\n\n"
        }
        return out
    }

    /// Format seconds as SRT's `HH:MM:SS,mmm`.
    static func srtTimestamp(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let totalMillis = Int((clamped * 1000).rounded())
        let millis = totalMillis % 1000
        let totalSeconds = totalMillis / 1000
        let secs = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }
}
