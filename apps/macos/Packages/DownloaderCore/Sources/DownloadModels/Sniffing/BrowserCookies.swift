import Foundation

/// Turns the in-app browser's cookie jar (`WKHTTPCookieStore` → `[HTTPCookie]`) into the two shapes
/// downstream consumers need: a per-URL `Cookie:` header for the engine's requests, and a Netscape
/// `cookies.txt` for the yt-dlp resolver (which needs the *whole multi-domain jar* — a youtube.com
/// extraction touches accounts.google.com too). Pure functions; the WebKit fetch stays in the app.
public enum BrowserCookies {
    /// The `Cookie:` header value a request to `url` should carry, honoring RFC 6265 send rules —
    /// domain match (host cookies exactly, domain cookies by suffix), path prefix, Secure-only over
    /// https, and expiry. `nil` when nothing applies.
    public static func cookieHeader(for url: URL, from cookies: [HTTPCookie]) -> String? {
        var applicable = cookies.filter { matches($0, url: url) }
        guard !applicable.isEmpty else { return nil }
        var header = HTTPCookie.requestHeaderFields(with: applicable)["Cookie"] ?? ""
        // An enormous jar must not overflow the capture validator's cookie cap — that would fail
        // the whole handoff (silently, after the shelf already showed it as grabbed). Drop the
        // least path-specific cookies until the header fits; a trimmed jar still authenticates.
        if header.count > CapturedDownload.Limits.cookies {
            applicable.sort { $0.path.count > $1.path.count }
            while header.count > CapturedDownload.Limits.cookies, applicable.count > 1 {
                applicable.removeLast()
                header = HTTPCookie.requestHeaderFields(with: applicable)["Cookie"] ?? ""
            }
            // A single cookie beyond the cap is pathological — send none rather than fail intake.
            if header.count > CapturedDownload.Limits.cookies { return nil }
        }
        return header.isEmpty ? nil : header
    }

    /// Should `cookie` be sent to `url`?
    static func matches(_ cookie: HTTPCookie, url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        let scheme = url.scheme?.lowercased() ?? ""
        if cookie.isSecure && scheme != "https" && scheme != "wss" { return false }
        if let expires = cookie.expiresDate, expires < Date() { return false }

        // Domain match. A leading dot (or a `.domain` set by the site) means "this host and
        // subdomains"; a bare domain sent by WebKit for a host-only cookie means exact match.
        let domain = cookie.domain.lowercased()
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        let domainMatches = domain.hasPrefix(".")
            ? (host == bare || host.hasSuffix("." + bare))
            : host == domain
        guard domainMatches, !bare.isEmpty else { return false }

        // Path prefix match (RFC 6265 §5.1.4-lite: exact, or prefix at a "/" boundary).
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        let requestPath = url.path.isEmpty ? "/" : url.path
        if requestPath == cookiePath { return true }
        if requestPath.hasPrefix(cookiePath) {
            return cookiePath.hasSuffix("/") || requestPath.dropFirst(cookiePath.count).first == "/"
        }
        return false
    }

    /// The jar as a Netscape `cookies.txt` — the format yt-dlp's `--cookies` reads. Session cookies
    /// get expiry `0`; names/values that would break the tab-separated format are dropped rather
    /// than mangled.
    public static func netscapeFile(_ cookies: [HTTPCookie]) -> String {
        var lines = ["# Netscape HTTP Cookie File"]
        for cookie in cookies {
            let name = cookie.name, value = cookie.value, domain = cookie.domain
            guard !name.isEmpty, !domain.isEmpty else { continue }
            let fields = [name, value, domain, cookie.path]
            guard !fields.contains(where: { $0.contains("\t") || $0.contains("\n") || $0.contains("\r") }) else { continue }
            let includeSubdomains = domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let secure = cookie.isSecure ? "TRUE" : "FALSE"
            let expires = cookie.expiresDate.map { String(Int(max(0, $0.timeIntervalSince1970))) } ?? "0"
            let path = cookie.path.isEmpty ? "/" : cookie.path
            lines.append([domain, includeSubdomains, path, secure, expires, name, value].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
