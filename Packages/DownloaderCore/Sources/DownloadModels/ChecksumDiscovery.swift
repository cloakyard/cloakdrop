import Foundation

/// Deriving and reading *sibling* checksum files, so a finished download can be verified against a
/// digest the site publishes next to it (e.g. `file.zip.sha256`).
///
/// Pure and I/O-free: this decides *what* to fetch (`siblingCandidates`) and *how* to read it
/// (`parse`); the engine's `ChecksumResolver` does the actual network fetching.
public enum ChecksumDiscovery {

    /// Sibling checksum URLs worth trying for `sourceURL`, strongest algorithm first: the download
    /// URL with a checksum extension appended (`file.zip` → `file.zip.sha256`, `.sha1`, `.md5`).
    ///
    /// Structurally same-origin (only an extension is appended). The download's query and fragment
    /// are dropped — published checksums are static files and rarely sit behind the same signed
    /// query as the payload. Returns `[]` for a URL with no file component (e.g. a bare directory).
    public static func siblingCandidates(for sourceURL: URL) -> [(url: URL, algorithm: ChecksumAlgorithm)] {
        guard var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) else { return [] }
        let path = components.path
        guard !path.isEmpty, !path.hasSuffix("/"), !(path as NSString).lastPathComponent.isEmpty else { return [] }
        components.query = nil
        components.fragment = nil

        // Strongest algorithm first — stop at the first that resolves + parses.
        let algorithmsByExtension: [(String, ChecksumAlgorithm)] = [
            ("sha256", .sha256), ("sha1", .sha1), ("md5", .md5)
        ]
        return algorithmsByExtension.compactMap { ext, algorithm in
            var candidate = components
            candidate.path = path + "." + ext
            return candidate.url.map { ($0, algorithm) }
        }
    }

    /// Extract the digest matching `fileName` from a checksum file's `contents`.
    ///
    /// Understands the layouts these files come in:
    ///   - a bare `<hex>` (the whole file is one digest),
    ///   - GNU coreutils `<hex>  name` / `<hex> *name` (text / binary mode),
    ///   - BSD / OpenSSL `SHA256 (name) = <hex>`,
    ///   - multi-file "SUMS" listings (the line whose file name matches `fileName` wins).
    ///
    /// Blank and `#`-comment lines are ignored. When no line's name matches but the file lists
    /// exactly one digest, that lone digest is used — a per-file sibling was fetched *for* this
    /// download, so it belongs to it even if the listed name differs (e.g. after a rename). Returns
    /// `nil` when nothing well-formed and unambiguous is found.
    public static func parse(
        _ contents: String,
        algorithm: ChecksumAlgorithm,
        fileName: String
    ) -> ChecksumExpectation? {
        let target = (fileName as NSString).lastPathComponent
        var loneDigest: String?
        var loneCount = 0

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            // BSD / OpenSSL: "SHA256 (name) = <hex>".
            if let bsd = parseBSD(line, algorithm: algorithm) {
                if bsd.name == target { return expectation(bsd.digest, algorithm) }
                loneDigest = bsd.digest; loneCount += 1
                continue
            }

            // coreutils "<hex>[  *name]" (or a bare "<hex>").
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard let candidate = tokens.first.map({ $0.lowercased() }), isDigest(candidate, algorithm) else { continue }
            if tokens.count == 1 {
                loneDigest = candidate; loneCount += 1
            } else {
                var name = tokens.dropFirst().joined(separator: " ")
                if name.hasPrefix("*") { name.removeFirst() }   // coreutils binary-mode marker
                if (name as NSString).lastPathComponent == target { return expectation(candidate, algorithm) }
                loneDigest = candidate; loneCount += 1
            }
        }

        if loneCount == 1, let loneDigest { return expectation(loneDigest, algorithm) }
        return nil
    }

    // MARK: - Helpers

    private static func isDigest(_ token: String, _ algorithm: ChecksumAlgorithm) -> Bool {
        token.count == algorithm.hexLength && token.allSatisfy(\.isHexDigit)
    }

    private static func expectation(_ digest: String, _ algorithm: ChecksumAlgorithm) -> ChecksumExpectation {
        ChecksumExpectation(algorithm: algorithm, expectedHex: digest)
    }

    /// Parse a BSD/OpenSSL line `ALGO (name) = <hex>` (spacing varies). Returns `nil` if the line
    /// isn't that shape or the digest isn't a well-formed `algorithm` digest.
    private static func parseBSD(_ line: String, algorithm: ChecksumAlgorithm) -> (digest: String, name: String)? {
        guard let equals = line.lastIndex(of: "="),
              let open = line.firstIndex(of: "("),
              let close = line.lastIndex(of: ")"),
              open < close, close < equals else { return nil }
        let digest = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces).lowercased()
        guard isDigest(digest, algorithm) else { return nil }
        let name = String(line[line.index(after: open)..<close])
        return (digest, (name as NSString).lastPathComponent)
    }
}
