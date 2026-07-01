import Foundation

/// Activates a security-scoped bookmark for the lifetime of a transfer, so a sandboxed
/// CloakDrop can write into a folder the user explicitly granted access to — even across
/// relaunches. A no-op when there's no bookmark (e.g. the default Downloads folder, which
/// the entitlement covers directly).
struct SecurityScope {
    private let url: URL?

    init(bookmark: Data?) {
        guard let bookmark else { self.url = nil; return }
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
