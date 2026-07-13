import Foundation

/// The single source of truth for deriving a download's file name. Every intake path — the add
/// sheet's pre-flight (`LinkInspector`), the engine's `add`, and the app's de-collision — resolves
/// names through here, so they can never drift apart.
public enum FileNaming {
    /// The best file name for a resource: the server's `Content-Disposition` name when it offers a
    /// usable one (reduced to its last path component), otherwise the (redirected) URL's last path
    /// component, then the host, and finally a generic fallback.
    public static func fileName(suggested: String? = nil, url: URL) -> String {
        if let suggested {
            let last = (suggested as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !last.isEmpty { return last }
        }
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/" { return last }
        if let host = url.host(), !host.isEmpty { return host }
        return "download"
    }
}
