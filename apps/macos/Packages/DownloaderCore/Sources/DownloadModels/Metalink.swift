import Foundation

/// A single downloadable file described by a Metalink document — one or more mirror URLs for the
/// same content, plus optional integrity data (a whole-file checksum and per-piece hashes). This is
/// the parsed, transport-agnostic shape the engine turns into a multi-source `Download`.
public struct MetalinkFile: Sendable, Equatable {
    /// The suggested output filename from the `name` attribute.
    public let name: String
    /// The advertised total size in bytes, if the document states one.
    public let size: Int64?
    /// Mirror URLs for this file, strongest (lowest `priority`) first.
    public let sources: [MetalinkSource]
    /// The strongest whole-file checksum offered (SHA-256 › SHA-1 › MD5), for post-download verification.
    public let checksum: ChecksumExpectation?
    /// Piece length in bytes for the per-piece hashes, when the document breaks the file into pieces.
    public let pieceLength: Int64?
    /// The algorithm the per-piece hashes use.
    public let pieceAlgorithm: ChecksumAlgorithm?
    /// Per-piece hex digests, in file order — each covers `pieceLength` bytes (the last piece is shorter).
    public let pieceHashes: [String]

    public init(
        name: String,
        size: Int64? = nil,
        sources: [MetalinkSource],
        checksum: ChecksumExpectation? = nil,
        pieceLength: Int64? = nil,
        pieceAlgorithm: ChecksumAlgorithm? = nil,
        pieceHashes: [String] = []
    ) {
        self.name = name
        self.size = size
        self.sources = sources
        self.checksum = checksum
        self.pieceLength = pieceLength
        self.pieceAlgorithm = pieceAlgorithm
        self.pieceHashes = pieceHashes
    }

    /// The mirror URLs alone, best-priority first — what the engine hands to the multi-source transfer.
    public var urls: [URL] { sources.map(\.url) }
}

/// One mirror for a Metalink file. `priority` follows the Metalink 4 convention: **lower is better**
/// (a Metalink 3 `preference`, where higher is better, is normalised into this space on parse).
public struct MetalinkSource: Sendable, Equatable {
    public let url: URL
    public let priority: Int

    public init(url: URL, priority: Int) {
        self.url = url
        self.priority = priority
    }
}
