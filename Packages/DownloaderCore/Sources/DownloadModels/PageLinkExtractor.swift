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
    /// Extract downloadable links from `html` relative to `baseURL`.
    ///
    /// - Parameters:
    ///   - html: the page source.
    ///   - baseURL: the page's URL, used to resolve relative links.
    ///   - extensions: when non-empty, keep only links whose path ends in one of these (lowercased,
    ///     without the dot — e.g. `["pdf", "zip"]`).
    public static func extract(html: String, baseURL: URL, extensions: Set<String> = []) -> [URL] {
        var seen = Set<URL>()
        var results: [URL] = []
        for raw in rawValues(in: html) {
            guard let resolved = resolve(raw, against: baseURL) else { continue }
            guard let scheme = resolved.scheme?.lowercased(),
                  ["http", "https", "ftp", "ftps"].contains(scheme) else { continue }
            if !extensions.isEmpty {
                let ext = resolved.pathExtension.lowercased()
                guard extensions.contains(ext) else { continue }
            }
            if seen.insert(resolved).inserted { results.append(resolved) }
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

    /// Every `href="…"` / `src="…"` attribute value (single or double quoted).
    private static func rawValues(in html: String) -> [String] {
        let pattern = #"(?:href|src)\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var values: [String] = []
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match else { return }
            for group in 1...2 {
                if let r = Range(match.range(at: group), in: html) {
                    let value = String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { values.append(value) }
                }
            }
        }
        return values
    }

    private static func resolve(_ raw: String, against baseURL: URL) -> URL? {
        // Skip in-page and non-resource references.
        let lowered = raw.lowercased()
        if raw.hasPrefix("#") || lowered.hasPrefix("javascript:") || lowered.hasPrefix("mailto:")
            || lowered.hasPrefix("data:") || lowered.hasPrefix("tel:") { return nil }
        return URL(string: raw, relativeTo: baseURL)?.absoluteURL
    }
}
