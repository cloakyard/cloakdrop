import Foundation

/// Pure FTP wire-protocol parsing — everything about FTP that doesn't touch a socket, so it can be
/// unit-tested without a server. The `FTPClient` layers `NWConnection` I/O on top of these.
///
/// FTP replies are ASCII, line-based, and CRLF-terminated. A reply is either a single line
/// `NNN text` (space after the 3-digit code) or a multi-line block that opens with `NNN-text` and
/// continues until a line begins with the same `NNN ` (code + space). See RFC 959 §4.2.
enum FTPProtocol {
    struct Reply: Equatable {
        let code: Int
        let text: String
        /// The reply class per RFC 959: 1xx positive-prelim, 2xx complete, 3xx intermediate,
        /// 4xx transient-negative, 5xx permanent-negative.
        var isPositiveCompletion: Bool { (200..<300).contains(code) }
        var isPositivePreliminary: Bool { (100..<200).contains(code) }
        var isPositiveIntermediate: Bool { (300..<400).contains(code) }
        var isNegative: Bool { code >= 400 }
    }

    /// Try to frame one complete reply out of `buffer`. Returns the reply plus the unconsumed
    /// remainder, or `nil` if the buffer doesn't yet hold a complete reply.
    static func parseReply(from buffer: String) -> (reply: Reply, remainder: String)? {
        let lines = buffer.components(separatedBy: "\r\n")
        // Need at least one terminated line (a trailing "" from the final CRLF).
        guard lines.count >= 2, let first = lines.first, first.count >= 4 else { return nil }
        let codeString = String(first.prefix(3))
        guard let code = Int(codeString), first.count >= 4 else { return nil }

        let separator = first[first.index(first.startIndex, offsetBy: 3)]
        if separator == " " {
            // Single-line reply — consume just the first line.
            let remainder = lines.dropFirst().joined(separator: "\r\n")
            return (Reply(code: code, text: first), remainder)
        }
        guard separator == "-" else { return nil }   // malformed 4th char

        // Multi-line: scan for the terminating "NNN " line.
        let terminator = codeString + " "
        for index in 1..<lines.count where lines[index].hasPrefix(terminator) {
            let block = lines[0...index].joined(separator: "\r\n")
            let remainder = lines[(index + 1)...].joined(separator: "\r\n")
            return (Reply(code: code, text: block), remainder)
        }
        return nil   // terminator not yet received
    }

    /// Parse the `h1,h2,h3,h4,p1,p2` tuple from a `227 Entering Passive Mode` reply into a host and
    /// port for the data connection.
    static func parsePassiveAddress(_ text: String) -> (host: String, port: Int)? {
        guard let open = text.firstIndex(of: "("), let close = text.firstIndex(of: ")"), open < close else { return nil }
        let inner = text[text.index(after: open)..<close]
        let parts = inner.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 6, parts.allSatisfy({ (0...255).contains($0) }) else { return nil }
        let host = "\(parts[0]).\(parts[1]).\(parts[2]).\(parts[3])"
        let port = parts[4] * 256 + parts[5]
        return (host, port)
    }

    /// Parse the port from a `229 Entering Extended Passive Mode (|||port|)` reply (RFC 2428). The
    /// data host is the same as the control connection's, so only the port is returned.
    static func parseExtendedPassivePort(_ text: String) -> Int? {
        guard let open = text.firstIndex(of: "("), let close = text.firstIndex(of: ")"), open < close else { return nil }
        let inner = text[text.index(after: open)..<close]
        // Format: (<d><d><d>port<d>) where <d> is a delimiter char (conventionally '|').
        let fields = inner.split(separator: inner.first ?? "|", omittingEmptySubsequences: true)
        guard let portField = fields.last, let port = Int(portField) else { return nil }
        return port
    }

    /// Parse the byte size from a `213 <size>` reply to `SIZE`.
    static func parseSize(_ text: String) -> Int64? {
        let parts = text.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let size = Int64(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return size
    }

    /// The path portion of an FTP URL, used as the argument to `SIZE`/`RETR`. Percent-decoded and
    /// defaulting to "/".
    static func path(for url: URL) -> String {
        let raw = url.path
        return raw.isEmpty ? "/" : raw
    }
}
