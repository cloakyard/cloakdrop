import Foundation

/// One-shot migration for machines that used the old browser extensions (removed in favour of the
/// built-in browser). Earlier builds wrote a native-messaging manifest into each installed
/// browser's real `~/Library/Application Support/<browser>/NativeMessagingHosts/` folder, pointing
/// at a `CloakDropNativeHost` helper that no longer ships. The stale JSON is inert (its target
/// binary is gone), but we remove it — and the security-scoped bookmarks that reach those
/// folders — so nothing dangling is left behind.
///
/// Best-effort and self-marking: it runs once, swallows every error (a since-revoked folder grant
/// just means we skip that browser's file), and never blocks launch.
enum LegacyExtensionCleanup {
    private static let doneKey = "legacyExtensionCleanupDone"
    private static let installedKey = "installedNativeMessagingHosts"       // was: Set<browser rawValue>
    private static let bookmarkKeyPrefix = "nativeMessagingBookmark."       // was: per-browser scoped bookmark
    private static let hostName = "com.cloakyard.cloakdrop"

    /// Run the cleanup once per machine. Cheap no-op on every launch after the first.
    static func runIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }

        let browsers = defaults.stringArray(forKey: installedKey) ?? []
        for browser in browsers {
            let bookmarkKey = bookmarkKeyPrefix + browser
            defer {
                defaults.removeObject(forKey: bookmarkKey)
            }
            guard let data = defaults.data(forKey: bookmarkKey) else { continue }
            var stale = false
            guard let base = try? URL(
                resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale
            ) else { continue }
            let scoped = base.startAccessingSecurityScopedResource()
            defer { if scoped { base.stopAccessingSecurityScopedResource() } }
            let hostsDir = base.lastPathComponent == "NativeMessagingHosts"
                ? base
                : base.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            try? FileManager.default.removeItem(at: hostsDir.appendingPathComponent("\(hostName).json"))
        }
        defaults.removeObject(forKey: installedKey)
    }
}
