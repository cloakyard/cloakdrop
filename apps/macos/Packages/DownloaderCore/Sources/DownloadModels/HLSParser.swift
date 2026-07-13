import Foundation

/// Why a manifest couldn't be parsed. Shared by the HLS and DASH parsers.
public enum MediaParseError: Error, Equatable {
    case notAPlaylist       // missing `#EXTM3U` (HLS) / unrecognised root (DASH)
    case noContent          // parsed cleanly but carried no variants or segments
    case malformed(String)
}

/// Parses HLS playlists (`.m3u8`) into a `MediaStream`.
///
/// Handles both playlist kinds: a **multivariant** playlist (the RFC 8216bis name for what older
/// specs called a "master" playlist — `#EXT-X-STREAM-INF` variants + `#EXT-X-MEDIA` audio/subtitle
/// renditions), whose variants carry a `playlistURL` to resolve later; and a **media** playlist
/// (`#EXTINF` segments), returned as a single resolved variant. Understands byte-range
/// segments (`#EXT-X-BYTERANGE`), fMP4 init segments (`#EXT-X-MAP`), and AES-128 keys (`#EXT-X-KEY`).
///
/// Pure and I/O-free — it's handed the already-fetched playlist text and the URL it came from (used
/// to resolve relative URIs), and is exercised directly with fixtures.
public enum HLSParser {
    public static func parse(_ text: String, baseURL: URL) throws -> MediaStream {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.first == "#EXTM3U" else { throw MediaParseError.notAPlaylist }

        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) {
            return try parseMultivariant(lines, baseURL: baseURL)
        }
        return try parseMedia(lines, baseURL: baseURL)
    }

    // MARK: Multivariant playlist

    private static func parseMultivariant(_ lines: [String], baseURL: URL) throws -> MediaStream {
        var variants: [MediaVariant] = []
        var audioTracks: [MediaTrack] = []
        var subtitleTracks: [MediaTrack] = []
        var pendingStreamInf: [String: String]?

        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingStreamInf = parseAttributes(after: "#EXT-X-STREAM-INF:", in: line)
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                if let track = makeTrack(parseAttributes(after: "#EXT-X-MEDIA:", in: line), baseURL: baseURL) {
                    switch track.kind {
                    case .audio: audioTracks.append(track)
                    case .subtitle: subtitleTracks.append(track)
                    }
                }
            } else if line.hasPrefix("#") {
                continue
            } else if let attrs = pendingStreamInf, let url = resolve(line, baseURL) {
                variants.append(makeVariant(id: variants.count, attrs, playlistURL: url))
                pendingStreamInf = nil
            }
        }

        guard !variants.isEmpty else { throw MediaParseError.noContent }
        return MediaStream(
            sourceURL: baseURL,
            format: .hls,
            variants: variants,
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks
        )
    }

    private static func makeVariant(id: Int, _ attrs: [String: String], playlistURL: URL) -> MediaVariant {
        let bandwidth = attrs["BANDWIDTH"].flatMap { Int($0) }
            ?? attrs["AVERAGE-BANDWIDTH"].flatMap { Int($0) } ?? 0
        let codecs = attrs["CODECS"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        return MediaVariant(
            id: "\(id)",
            bandwidth: bandwidth,
            resolution: attrs["RESOLUTION"].flatMap(parseResolution),
            codecs: codecs,
            frameRate: attrs["FRAME-RATE"].flatMap { Double($0) },
            playlistURL: playlistURL,
            audioGroupID: attrs["AUDIO"],
            subtitleGroupID: attrs["SUBTITLES"]
        )
    }

    private static func makeTrack(_ attrs: [String: String], baseURL: URL) -> MediaTrack? {
        let kind: MediaTrack.Kind
        switch attrs["TYPE"] {
        case "AUDIO": kind = .audio
        case "SUBTITLES": kind = .subtitle
        default: return nil // CLOSED-CAPTIONS et al. carry no downloadable URI
        }
        return MediaTrack(
            id: "\(attrs["GROUP-ID"] ?? "")-\(attrs["NAME"] ?? attrs["LANGUAGE"] ?? "track")",
            kind: kind,
            groupID: attrs["GROUP-ID"],
            name: attrs["NAME"],
            language: attrs["LANGUAGE"],
            isDefault: attrs["DEFAULT"] == "YES",
            playlistURL: attrs["URI"].flatMap { resolve($0, baseURL) }
        )
    }

    // MARK: Media playlist

    private static func parseMedia(_ lines: [String], baseURL: URL) throws -> MediaStream {
        var segments: [MediaSegment] = []
        var sequence = 0
        var key: MediaEncryption = .none
        var initSegment: MediaInitSegment?
        var pendingDuration: Double?
        var pendingByteRange: MediaByteRange?
        var lastByteEnd: Int64 = -1

        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(value(after: "#EXT-X-MEDIA-SEQUENCE:", in: line)) ?? 0
            } else if line.hasPrefix("#EXTINF:") {
                let raw = value(after: "#EXTINF:", in: line)
                pendingDuration = Double(raw.split(separator: ",", maxSplits: 1).first.map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? "")
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingByteRange = parseByteRange(value(after: "#EXT-X-BYTERANGE:", in: line), previousEnd: lastByteEnd)
            } else if line.hasPrefix("#EXT-X-KEY:") {
                key = parseKey(parseAttributes(after: "#EXT-X-KEY:", in: line), baseURL: baseURL)
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = parseAttributes(after: "#EXT-X-MAP:", in: line)
                if let uri = attrs["URI"], let url = resolve(uri, baseURL) {
                    initSegment = MediaInitSegment(url: url, byteRange: attrs["BYTERANGE"].flatMap { parseByteRange($0, previousEnd: -1) })
                }
            } else if line.hasPrefix("#") {
                continue
            } else if let url = resolve(line, baseURL) {
                segments.append(MediaSegment(
                    id: sequence,
                    url: url,
                    duration: pendingDuration ?? 0,
                    byteRange: pendingByteRange,
                    encryption: key
                ))
                if let range = pendingByteRange { lastByteEnd = range.end }
                sequence += 1
                pendingDuration = nil
                pendingByteRange = nil
            }
        }

        guard !segments.isEmpty else { throw MediaParseError.noContent }
        let variant = MediaVariant(id: "0", bandwidth: 0, initSegment: initSegment, segments: segments)
        return MediaStream(sourceURL: baseURL, format: .hls, variants: [variant])
    }

    private static func parseKey(_ attrs: [String: String], baseURL: URL) -> MediaEncryption {
        switch attrs["METHOD"] {
        case "NONE", nil:
            return .none
        case "AES-128":
            return MediaEncryption(
                method: .aes128,
                keyURL: attrs["URI"].flatMap { resolve($0, baseURL) },
                iv: attrs["IV"].flatMap(parseIV)
            )
        default:
            // SAMPLE-AES and any other non-cleartext method: recorded as encrypted-but-unsupported so
            // the UI can explain it, never silently treated as cleartext.
            return MediaEncryption(
                method: .sampleAES,
                keyURL: attrs["URI"].flatMap { resolve($0, baseURL) },
                iv: attrs["IV"].flatMap(parseIV)
            )
        }
    }

    // MARK: Scalar parsing

    /// Split an HLS attribute list into a dictionary, respecting quoted values (so a comma inside
    /// `CODECS="avc1,mp4a"` isn't treated as a separator). Surrounding quotes are stripped.
    static func parseAttributes(after tag: String, in line: String) -> [String: String] {
        parseAttributeList(String(line.dropFirst(tag.count)))
    }

    static func parseAttributeList(_ list: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var inQuotes = false

        for char in list {
            if readingKey {
                if char == "=" { readingKey = false } else { key.append(char) }
            } else if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                result[key.trimmingCharacters(in: .whitespaces)] = value
                key = ""; value = ""; readingKey = true
            } else {
                value.append(char)
            }
        }
        if !key.isEmpty { result[key.trimmingCharacters(in: .whitespaces)] = value }
        return result
    }

    private static func value(after tag: String, in line: String) -> String {
        String(line.dropFirst(tag.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func parseResolution(_ raw: String) -> MediaResolution? {
        let parts = raw.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
        return MediaResolution(width: width, height: height)
    }

    /// `length[@offset]`. A missing offset continues from the previous byte-range's end (HLS spec);
    /// `previousEnd < 0` means "no previous range", so a missing offset starts at 0.
    private static func parseByteRange(_ raw: String, previousEnd: Int64) -> MediaByteRange? {
        let parts = raw.split(separator: "@", maxSplits: 1)
        guard let length = Int64(parts[0].trimmingCharacters(in: .whitespaces)), length > 0 else { return nil }
        let offset: Int64
        if parts.count == 2, let parsed = Int64(parts[1].trimmingCharacters(in: .whitespaces)) {
            offset = parsed
        } else {
            offset = previousEnd < 0 ? 0 : previousEnd + 1
        }
        // Reject a negative or overflowing range so `end` (offset + length - 1) is always valid.
        guard offset >= 0, offset <= Int64.max - length else { return nil }
        return MediaByteRange(offset: offset, length: length)
    }

    /// `0x` + 32 hex chars → 16 bytes.
    private static func parseIV(_ raw: String) -> Data? {
        var hex = raw.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
        guard hex.count == 32 else { return nil }
        var data = Data(capacity: 16)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func resolve(_ uri: String, _ baseURL: URL) -> URL? {
        URL(string: uri, relativeTo: baseURL)?.absoluteURL
    }
}
