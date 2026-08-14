import Foundation

/// A local evidence record for an ordinary file download, assembled from signals CloakDrop actually
/// persists: the requested source and configured mirrors, encrypted-transport flag, the file's own
/// SHA-256, any checksum match, and an available code-signing verdict. The receipt's trust verdict is
/// derived specifically from checksum and signature status; the other fields are evidence only. The
/// receipt remains on the Mac unless the user exports it; it is not itself signed or tamper-evident.
///
/// A `Sendable`, `Codable` value so it persists on the `Download` and can be written out verbatim.
public struct ProvenanceReceipt: Sendable, Hashable, Codable {
    public let fileName: String
    public let fileSizeBytes: Int64?
    /// The URL the download was requested from.
    public let sourceURL: URL
    /// The URL bytes were actually fetched from, after any redirects (when the client tracks it).
    public let finalURL: URL?
    /// Additional Metalink mirrors available for the same content.
    public let mirrors: [URL]
    /// Whether the transport was encrypted (`https`/`ftps`).
    public let transportSecure: Bool
    /// The finished file's SHA-256, computed on completion (lowercased hex). `nil` if it couldn't be read.
    public let sha256: String?
    /// The checksum the file was expected to match, if any.
    public let expectedChecksum: ChecksumExpectation?
    /// Whether the file matched `expectedChecksum` (or an auto-discovered sibling). `nil` = not checked.
    public let checksumVerified: Bool?
    /// The code-signature verdict for installable types (`.app`/`.dmg`).
    public let signature: SignatureAssessment?
    /// The checksum/signature-derived trust verdict (mirrors `Download.trustLevel`).
    public let trustLevel: TrustLevel
    public let generatedAt: Date

    public init(
        fileName: String,
        fileSizeBytes: Int64?,
        sourceURL: URL,
        finalURL: URL?,
        mirrors: [URL],
        transportSecure: Bool,
        sha256: String?,
        expectedChecksum: ChecksumExpectation?,
        checksumVerified: Bool?,
        signature: SignatureAssessment?,
        trustLevel: TrustLevel,
        generatedAt: Date
    ) {
        self.fileName = fileName
        self.fileSizeBytes = fileSizeBytes
        self.sourceURL = sourceURL
        self.finalURL = finalURL
        self.mirrors = mirrors
        self.transportSecure = transportSecure
        self.sha256 = sha256
        self.expectedChecksum = expectedChecksum
        self.checksumVerified = checksumVerified
        self.signature = signature
        self.trustLevel = trustLevel
        self.generatedAt = generatedAt
    }

    /// A plain-text receipt suitable for saving next to the download or pasting into an email. Kept
    /// deterministic (no locale-dependent formatting beyond the timestamp) so two receipts for the
    /// same download are byte-identical.
    /// Strip control characters (notably CR/LF) from a field so an attacker-influenced value — a
    /// server-suggested filename may legally contain newlines — can't inject forged lines like
    /// "Trust: verified" into a record whose whole point is to be a trustworthy attestation.
    private func sanitize(_ value: String) -> String {
        String(value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
    }

    public func exportText(dateStyle: ISO8601DateFormatter = ISO8601DateFormatter()) -> String {
        var lines: [String] = []
        lines.append("CloakDrop — Download Provenance Receipt")
        lines.append(String(repeating: "=", count: 40))
        lines.append("File:        \(sanitize(fileName))")
        if let fileSizeBytes { lines.append("Size:        \(fileSizeBytes) bytes") }
        lines.append("Source:      \(sanitize(sourceURL.absoluteString))")
        if let finalURL, finalURL != sourceURL { lines.append("Resolved to: \(sanitize(finalURL.absoluteString))") }
        if !mirrors.isEmpty { lines.append("Mirrors:     \(sanitize(mirrors.map(\.absoluteString).joined(separator: ", ")))") }
        lines.append("Transport:   \(transportSecure ? "encrypted (TLS)" : "cleartext")")
        if let sha256 { lines.append("SHA-256:     \(sha256)") }
        if let expectedChecksum {
            let verdict = checksumVerified == true ? "matched" : (checksumVerified == false ? "MISMATCH" : "not verified")
            lines.append("Checksum:    \(expectedChecksum.algorithm.displayName) — \(verdict)")
        }
        if let signature {
            let signer = signature.authority.map { " (\($0))" } ?? ""
            lines.append("Signature:   \(signature.status.rawValue)\(signer)")
        }
        lines.append("Trust:       \(trustLevel.rawValue)")
        lines.append("Generated:   \(dateStyle.string(from: generatedAt))")
        return lines.joined(separator: "\n") + "\n"
    }
}
