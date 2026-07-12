import Foundation

/// Stamps a finished download with the `com.apple.quarantine` flag — the same marker a browser
/// applies — so Gatekeeper vets the file the first time the user opens it (and shows the "downloaded
/// from the internet" prompt for apps/installers). Without this, files CloakDrop writes are trusted
/// silently, which is a weaker security posture than every mainstream browser and download manager.
///
/// It only ever writes an extended attribute on a file the app already owns — no network, no extra
/// entitlement — so it stays inside the sandbox. Best-effort: a filesystem that can't carry xattrs
/// simply leaves the file unquarantined rather than failing the download.
enum Quarantine {
    /// The extended attribute Gatekeeper reads.
    static let attributeName = "com.apple.quarantine"

    /// Apply the quarantine flag to the file at `path`.
    ///
    /// The value is LaunchServices' four-field format `flags;timestamp;agent;uuid`. Flags `0001` marks
    /// a web download **without** the `0x40` "user-approved" bit — so Gatekeeper still evaluates it on
    /// first open, exactly like a browser download. The source/origin URLs live in the Provenance
    /// Receipt rather than here; the flag is all Gatekeeper needs.
    static func apply(toPath path: String, sourceURL: URL? = nil, originURL: URL? = nil, agentName: String = "CloakDrop") {
        let timestamp = String(format: "%08x", UInt32(truncatingIfNeeded: Int(max(0, Date().timeIntervalSince1970))))
        let value = "0001;\(timestamp);\(agentName);\(UUID().uuidString)"
        value.withCString { cString in
            _ = setxattr(path, attributeName, cString, strlen(cString), 0, 0)
        }
    }

    /// Whether the file at `path` currently carries the quarantine flag. Used by tests and by any
    /// caller that wants to avoid re-stamping an already-quarantined file.
    static func isQuarantined(path: String) -> Bool {
        getxattr(path, attributeName, nil, 0, 0, 0) >= 0
    }
}
