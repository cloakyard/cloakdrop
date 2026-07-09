import Foundation

/// Cross-process transport for `CapturedDownload` from the Share Extension to the main app.
///
/// Sandboxed processes can't call each other directly, so a capture crosses the boundary as a
/// JSON file dropped into a shared **App Group** container (the "inbox"), paired with a
/// payload-free **Darwin notification** that wakes the app to drain it. Two halves, by design:
/// the notification is a system-wide signal that carries no data (so cookies/headers never leak
/// through it), and the file carries the data but only within the container both sides are
/// entitled to. A notification missed because the app wasn't running is recovered by draining the
/// inbox on launch.
///
/// Foundation-only and dependency-free so both the app target and the lightweight Share Extension target
/// can link it without pulling in the engine.
public enum CaptureInbox {
    /// The App Group both the app and its Share Extension declare in their entitlements. Changing
    /// this requires updating `CloakDrop.entitlements` and the Share Extension's entitlements in lockstep.
    public static let appGroupID = "group.com.cloakyard.cloakdrop"

    /// Payload-free wake signal posted after a capture is written; the data rides the inbox files.
    public static let darwinNotificationName = "com.cloakyard.cloakdrop.capture"

    /// The shared container root, or `nil` if the App Group isn't provisioned (e.g. an unsigned
    /// build without the entitlement) — callers degrade gracefully rather than crash.
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private static var inboxURL: URL? {
        containerURL?.appendingPathComponent("captures", isDirectory: true)
    }

    /// Why a write couldn't happen. Reading never throws — malformed files are just skipped.
    public enum InboxError: Error, Equatable {
        case containerUnavailable
    }

    /// Persist a capture as a uniquely-named JSON file in the inbox (the Share Extension side). Assumes
    /// the capture is already `validated()`. Atomic so the app never reads a half-written file.
    @discardableResult
    public static func write(_ capture: CapturedDownload) throws -> URL {
        guard let inbox = inboxURL else { throw InboxError.containerUnavailable }
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let file = inbox.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        try JSONEncoder().encode(capture).write(to: file, options: .atomic)
        return file
    }

    /// Read and remove every pending capture, oldest first (the app side). Files that fail to
    /// decode or re-validate are discarded, not surfaced — a corrupt or hostile drop can't wedge
    /// the inbox or reach the UI. Returns an empty array when the container is unavailable.
    public static func drain() -> [CapturedDownload] {
        let manager = FileManager.default
        guard let inbox = inboxURL,
              let files = try? manager.contentsOfDirectory(
                at: inbox,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        let ordered = files
            .filter { $0.pathExtension == "json" }
            .sorted { modificationDate($0) < modificationDate($1) }

        var captures: [CapturedDownload] = []
        for file in ordered {
            defer { try? manager.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let decoded = try? JSONDecoder().decode(CapturedDownload.self, from: data),
                  let valid = try? decoded.validated() else { continue }
            captures.append(valid)
        }
        return captures
    }

    /// Broadcast the payload-free wake signal (the Share Extension side, after `write`).
    public static func postNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(darwinNotificationName as CFString),
            nil, nil, true
        )
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
