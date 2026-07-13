import Foundation

/// A content-integrity algorithm CloakDrop can verify a finished file against.
public enum ChecksumAlgorithm: String, Sendable, Hashable, Codable, CaseIterable {
    case md5
    case sha1
    case sha256

    /// Display name as users expect to see it (e.g. on checksum pages).
    public var displayName: String {
        switch self {
        case .md5: return "MD5"
        case .sha1: return "SHA-1"
        case .sha256: return "SHA-256"
        }
    }

    /// Number of hex characters a digest of this algorithm produces.
    public var hexLength: Int {
        switch self {
        case .md5: return 32
        case .sha1: return 40
        case .sha256: return 64
        }
    }
}

/// An expected checksum to verify a completed download against.
public struct ChecksumExpectation: Sendable, Hashable, Codable {
    public let algorithm: ChecksumAlgorithm
    /// Lowercased, whitespace-trimmed hex digest the file is expected to match.
    public let expectedHex: String

    public init(algorithm: ChecksumAlgorithm, expectedHex: String) {
        self.algorithm = algorithm
        self.expectedHex = expectedHex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Whether `expectedHex` is a syntactically valid digest for `algorithm`.
    public var isWellFormed: Bool {
        expectedHex.count == algorithm.hexLength
            && expectedHex.allSatisfy(\.isHexDigit)
    }

    /// Whether this is a real digest to verify against, rather than an all-zero placeholder. Some
    /// tools and servers emit an all-zero hash to mean "none"; real content never hashes to all
    /// zeros, so such a value is treated as "no usable checksum" (unverifiable, shown as unavailable).
    public var isUsable: Bool {
        isWellFormed && expectedHex.contains { $0 != "0" }
    }
}
