/// A single, unified trust signal for a download, distilled from its checksum result and its code
/// signature so the UI can show one badge. Ordered by severity: a failure always outranks a pass.
public enum TrustLevel: String, Sendable, Hashable, Codable {
    /// Nothing to vouch for (or nothing yet) — no badge.
    case unknown
    /// At least one integrity check passed and none failed — a positive, green badge.
    case verified
    /// An integrity check failed (checksum mismatch or an invalid signature) — a red warning badge.
    case warning
}

public extension Download {
    /// The download's unified trust level for the badge. A negative signal (checksum mismatch or an
    /// invalid code signature) always wins, so a failure can never be masked by an unrelated pass;
    /// otherwise any positive signal (a matched checksum or a valid signature) reads as verified.
    var trustLevel: TrustLevel {
        // Negative first — a failed integrity check must never render as "verified".
        if checksumVerified == false { return .warning }
        if signature?.status == .invalid { return .warning }
        // Then positives.
        if checksumVerified == true { return .verified }
        if signature?.status == .valid { return .verified }
        return .unknown
    }
}
