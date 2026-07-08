import Foundation

/// Pure helpers for turning user text into a list of download URLs: parsing pasted lists /
/// `.txt` imports, and expanding numeric/alpha range patterns like `file[01-50].zip`.
///
/// Kept free of I/O and UI so it can be exhaustively unit-tested.
public enum URLBatch {

    /// The largest number of URLs a single pattern may expand to, to guard against
    /// accidental combinatorial explosions (e.g. `[0-99][0-99][0-99]`).
    public static let expansionLimit = 10_000

    /// Parse free-form text (one URL per line, or whitespace-separated) into normalized,
    /// de-duplicated http(s) URLs. Each line may itself be a range pattern, which is expanded.
    public static func parse(_ text: String) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        let tokens = text.split(whereSeparator: { $0.isNewline || $0 == " " || $0 == "\t" })
        for token in tokens {
            for url in expand(String(token)) where seen.insert(url.absoluteString).inserted {
                result.append(url)
            }
        }
        return result
    }

    /// Expand a single token. If it contains range patterns, returns every concrete URL;
    /// otherwise returns the single normalized URL (or nothing if invalid).
    public static func expand(_ token: String) -> [URL] {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let segments = expandPatterns(in: trimmed)
        return segments.compactMap(normalized)
    }

    /// Whether a token contains an expandable `[a-b]` range pattern.
    public static func containsPattern(_ token: String) -> Bool {
        firstRange(in: token) != nil
    }

    // MARK: - Pattern expansion

    /// Recursively expand every `[start-end]` group via a cartesian product, capping output.
    private static func expandPatterns(in string: String) -> [String] {
        guard let match = firstRange(in: string) else { return [string] }

        let prefix = String(string[string.startIndex..<match.range.lowerBound])
        let suffix = String(string[match.range.upperBound...])
        let values = match.values

        var output: [String] = []
        for value in values {
            for expandedSuffix in expandPatterns(in: suffix) {
                output.append(prefix + value + expandedSuffix)
                if output.count >= expansionLimit { return output }
            }
        }
        return output
    }

    private struct RangeMatch {
        let range: Range<String.Index>
        let values: [String]
    }

    /// Find the first `[a-b]` pattern and the concrete strings it expands to.
    private static func firstRange(in string: String) -> RangeMatch? {
        guard let open = string.firstIndex(of: "["),
              let close = string[open...].firstIndex(of: "]"),
              close > open else { return nil }

        let inner = String(string[string.index(after: open)..<close])
        let parts = inner.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let lower = String(parts[0])
        let upper = String(parts[1])

        let values: [String]
        if let numeric = numericRange(lower, upper) {
            values = numeric
        } else if let alpha = alphaRange(lower, upper) {
            values = alpha
        } else {
            return nil
        }

        return RangeMatch(range: open..<string.index(after: close), values: values)
    }

    /// Expand `01-50` → ["01", …, "50"], preserving zero-padding width.
    private static func numericRange(_ lower: String, _ upper: String) -> [String]? {
        guard lower.allSatisfy(\.isNumber), upper.allSatisfy(\.isNumber),
              let start = Int(lower), let end = Int(upper), start <= end else { return nil }
        let width = max(lower.count, upper.count)
        let padded = lower.first == "0" && lower.count > 1
        return (start...end).map { value in
            padded ? String(format: "%0\(width)d", value) : String(value)
        }
    }

    /// Expand `a-f` / `A-F` → consecutive single letters. Restricted to *same-case* ASCII
    /// letters so a cross-case pattern like `[A-z]` (whose scalar span includes `[ \ ] ^ _ \``)
    /// is rejected rather than expanded into punctuation-laced garbage URLs.
    private static func alphaRange(_ lower: String, _ upper: String) -> [String]? {
        guard lower.count == 1, upper.count == 1,
              let lo = lower.unicodeScalars.first, let hi = upper.unicodeScalars.first,
              lo.value <= hi.value else { return nil }
        let uppercase: ClosedRange<UInt32> = 65...90   // A...Z
        let lowercase: ClosedRange<UInt32> = 97...122  // a...z
        let sameCase = (uppercase.contains(lo.value) && uppercase.contains(hi.value))
            || (lowercase.contains(lo.value) && lowercase.contains(hi.value))
        guard sameCase else { return nil }
        return (lo.value...hi.value).compactMap { Unicode.Scalar($0).map { String($0) } }
    }

    // MARK: - Normalization

    /// Validate and normalize a single URL string, adding `https://` when no scheme is present.
    public static func normalized(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https", "ftp", "ftps"].contains(scheme) {
            return url
        }
        // Accept a bare host (we'll prepend https://) only if it actually looks like one — a
        // dotted name/IP or `localhost`. Otherwise a stray word ("notes", "todo") on its own
        // line would silently become a bogus download; the batch contract is to drop junk.
        if let url = URL(string: "https://\(trimmed)"), let host = url.host(),
           host == "localhost" || host.contains(".") {
            return url
        }
        return nil
    }
}
