import Foundation

/// Activates a security-scoped bookmark for the lifetime of a transfer — or any later read of the
/// finished file (thumbnails, previews) — so a sandboxed CloakDrop can touch a folder the user
/// explicitly granted access to, even across relaunches. A no-op when there's no bookmark (e.g. the
/// default Downloads folder, which the entitlement covers directly).
public struct SecurityScope {
    public let resolvedURL: URL?
    public let isStale: Bool
    private let originalPath: String?
    /// Whether a bookmark was supplied at all — lets the caller tell "no scope needed" (the default,
    /// entitlement-covered Downloads folder) apart from "a scope was expected but couldn't be opened".
    public let hasBookmark: Bool

    public init(bookmark: Data?) {
        hasBookmark = bookmark != nil
        var stale = false
        resolvedURL = bookmark.flatMap {
            try? URL(resolvingBookmarkData: $0, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
        }
        isStale = stale
        // Read metadata only from bookmark data that resolved successfully.
        originalPath = resolvedURL == nil ? nil
            : bookmark.flatMap { URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: $0)?.path }
    }

    /// Follow a moved bookmark while retaining only descendants of its original directory. This
    /// updates paths, never moves files; staging data moves with the user-selected folder itself.
    public func resolvedPath(for path: String) -> String? {
        guard let resolvedURL else { return nil }
        let components = Self.canonicalComponents(path)
        let resolved = Self.canonicalComponents(resolvedURL.path)
        let original = originalPath.map(Self.canonicalComponents) ?? resolved
        // A replacement directory at the old path can win Foundation's bookmark resolution. A
        // stale bookmark that stayed at the same path cannot prove identity; require a fresh choice.
        guard !isStale || resolved != original else { return nil }
        for base in [original, resolved] where components.starts(with: base) {
            return NSString.path(withComponents: resolved + components.dropFirst(base.count))
        }
        return nil
    }

    /// Call while access is active, and persist the result in place of the stale bookmark.
    public func refreshedBookmark() throws -> Data? {
        guard isStale, let resolvedURL else { return nil }
        return try resolvedURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: [.pathKey])
    }

    private static func canonicalComponents(_ path: String) -> [String] {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var missing: [String] = []
        // The original directory may no longer exist. Resolve aliases in its nearest existing
        // ancestor (including /var versus /private/var) and retain the missing path components.
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            missing.append(url.lastPathComponent)
            url.deleteLastPathComponent()
        }
        return url.resolvingSymlinksInPath().pathComponents + missing.reversed()
    }

    /// Begin access; returns whether a scope was actually started (caller must balance with `stop`).
    @discardableResult
    public func start() -> Bool {
        resolvedURL?.startAccessingSecurityScopedResource() ?? false
    }

    public func stop() {
        resolvedURL?.stopAccessingSecurityScopedResource()
    }
}
