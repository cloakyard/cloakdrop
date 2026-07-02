import Foundation

/// Activates a security-scoped bookmark for the lifetime of a transfer, so a sandboxed
/// CloakDrop can write into a folder the user explicitly granted access to — even across
/// relaunches. A no-op when there's no bookmark (e.g. the default Downloads folder, which
/// the entitlement covers directly).
struct SecurityScope {
    private let url: URL?
    /// Whether a bookmark was supplied at all — lets the caller tell "no scope needed" (the default,
    /// entitlement-covered Downloads folder) apart from "a scope was expected but couldn't be opened".
    let hasBookmark: Bool

    init(bookmark: Data?) {
        guard let bookmark else { self.url = nil; self.hasBookmark = false; return }
        self.hasBookmark = true
        var stale = false
        self.url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    /// Begin access; returns whether a scope was actually started (caller must balance with `stop`).
    @discardableResult
    func start() -> Bool {
        url?.startAccessingSecurityScopedResource() ?? false
    }

    func stop() {
        url?.stopAccessingSecurityScopedResource()
    }
}
