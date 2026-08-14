import Foundation

/// Pulls downloadable links out of a single web page's HTML — the engine behind "grab everything on
/// this page." Pure and I/O-free: the caller fetches the HTML (a user-initiated request to a
/// user-opened page), this extracts and resolves the URLs, so it's fully unit-testable and stays a
/// **single-page** operation — never a crawler that follows links off the page.
///
/// It scans `href`/`src` attributes (anchors, images, media, sources), resolves them against the page
/// URL, keeps only http(s)/ftp(s) resources, and dedupes — optionally narrowing to a set of file
/// extensions so "all the PDFs" or "all the images" is one filter away.
public enum PageLinkExtractor {
    private static let maximumExaminedCandidates = 100_000

    /// Extract downloadable links from `html` relative to `baseURL`.
    ///
    /// - Parameters:
    ///   - html: the page source.
    ///   - baseURL: the page's URL, used to resolve relative links.
    ///   - extensions: when non-empty, keep only links whose path ends in one of these (lowercased,
    ///     without the dot — e.g. `["pdf", "zip"]`).
    public static func extract(
        html: String,
        baseURL: URL,
        extensions: Set<String> = [],
        maximumCount: Int = URLBatch.expansionLimit
    ) -> [URL] {
        guard maximumCount > 0 else { return [] }
        let pattern = #"(?:href|src)\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        var seen = Set<URL>()
        var results: [URL] = []
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var examined = 0
        regex.enumerateMatches(in: html, range: range) { match, _, stop in
            guard let match else { return }
            for group in 1...2 where results.count < maximumCount {
                guard let rawRange = Range(match.range(at: group), in: html) else { continue }
                examined += 1
                guard examined <= maximumExaminedCandidates else {
                    stop.pointee = true
                    return
                }
                let raw = html[rawRange].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty, let resolved = resolve(raw, against: baseURL),
                      let scheme = resolved.scheme?.lowercased(),
                      ["http", "https", "ftp", "ftps"].contains(scheme) else { continue }
                if !extensions.isEmpty, !extensions.contains(resolved.pathExtension.lowercased()) { continue }
                if seen.insert(resolved).inserted { results.append(resolved) }
            }
            if results.count == maximumCount { stop.pointee = true }
        }
        return results
    }

    /// The distinct file extensions present among the extracted links — drives a "filter by type" UI.
    public static func availableExtensions(html: String, baseURL: URL) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for url in extract(html: html, baseURL: baseURL) {
            let ext = url.pathExtension.lowercased()
            guard !ext.isEmpty, seen.insert(ext).inserted else { continue }
            order.append(ext)
        }
        return order.sorted()
    }

    // MARK: Parsing

    private static func resolve(_ raw: String, against baseURL: URL) -> URL? {
        // Skip in-page and non-resource references.
        let lowered = raw.lowercased()
        if raw.hasPrefix("#") || lowered.hasPrefix("javascript:") || lowered.hasPrefix("mailto:")
            || lowered.hasPrefix("data:") || lowered.hasPrefix("tel:") { return nil }
        // HTML attribute values carry entity-encoded ampersands (`a=1&amp;b=2`); decode the common ones
        // so the query survives, then percent-encode anything URL(string:) would otherwise reject (a
        // space in a filename would make it return nil and the link would silently vanish). The allowed
        // set keeps reserved URL characters — including `%`, so existing escapes aren't double-encoded.
        let decoded = decodeEntities(raw)
        let allowed = CharacterSet(charactersIn: "!#$&'()*+,-./:;=?@_~%[]").union(.alphanumerics)
        let encoded = decoded.addingPercentEncoding(withAllowedCharacters: allowed) ?? decoded
        return URL(string: encoded, relativeTo: baseURL)?.absoluteURL
    }

    /// Decode the handful of HTML entities that actually appear inside URLs.
    private static func decodeEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        return value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&#x26;", with: "&")
    }
}
