import Foundation

/// The single source of truth for deriving a download's file name. Every intake path — the add
/// sheet's pre-flight (`LinkInspector`), the engine's `add`, and the app's de-collision — resolves
/// names through here, so they can never drift apart.
public enum FileNaming {
    /// The best file name for a resource: the server's `Content-Disposition` name when it offers a
    /// usable one (reduced to its last path component), otherwise the (redirected) URL's last path
    /// component, then the host, and finally a generic fallback.
    public static func fileName(suggested: String? = nil, url: URL) -> String {
        if let suggested = safeBasename(suggested) { return suggested }
        // `URL.lastPathComponent` percent-decodes. A crafted final component such as
        // `file%2F..%2Fescape` can therefore contain separators even though the URL itself has only
        // one path component, so URL-derived names go through the same basename gate.
        if let last = safeBasename(url.lastPathComponent) { return last }
        if let host = safeBasename(url.host()) { return host }
        return "download"
    }

    /// Reduce untrusted server/user text to one ordinary path component. Both slash styles are
    /// treated as separators (captures can originate on another platform), control characters are
    /// removed, and the special `.` / `..` components are rejected rather than allowed to address a
    /// directory outside the chosen destination.
    private static func safeBasename(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        guard let component = normalized.split(separator: "/", omittingEmptySubsequences: true).last else {
            return nil
        }
        let cleaned = String(component)
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return nil }
        return cleaned
    }
}
