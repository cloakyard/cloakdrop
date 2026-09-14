/// One contiguous byte range of a download, transferred over its own HTTP connection.
///
/// A segment owns the closed byte interval `[start, end]` (inclusive `end`, matching
/// the semantics of the HTTP `Range` header). `downloadedBytes` is the number of bytes
/// already written for this segment, so the next resume request starts at
/// `start + downloadedBytes`.
public struct DownloadSegment: Sendable, Hashable, Codable, Identifiable {
    public let id: Int
    /// Absolute offset of the first byte this segment is responsible for.
    public let start: Int64
    /// Absolute offset of the last byte this segment is responsible for (inclusive).
    public let end: Int64
    /// Bytes already written for this segment.
    public var downloadedBytes: Int64

    public init(id: Int, start: Int64, end: Int64, downloadedBytes: Int64 = 0) {
        precondition(end >= start, "segment end must be >= start")
        precondition(downloadedBytes >= 0, "downloadedBytes must be non-negative")
        self.id = id
        self.start = start
        self.end = end
        self.downloadedBytes = downloadedBytes
    }

    /// Persisted offsets are untrusted: synthesized decoding bypasses the initializer and could
    /// otherwise admit negative writes or overflow before the engine can recover the download.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        start = try container.decode(Int64.self, forKey: .start)
        end = try container.decode(Int64.self, forKey: .end)
        downloadedBytes = try container.decode(Int64.self, forKey: .downloadedBytes)
        guard id >= 0, start >= 0, end >= start, end < Int64.max,
              downloadedBytes >= 0, downloadedBytes <= end - start + 1 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Invalid persisted download segment."
            ))
        }
    }

    /// Total number of bytes this segment must transfer.
    public var length: Int64 { end - start + 1 }

    /// Bytes still to be fetched for this segment.
    public var remainingBytes: Int64 { max(0, length - downloadedBytes) }

    /// The absolute offset at which the next byte should be written.
    public var currentOffset: Int64 { start + downloadedBytes }

    /// Whether this segment has transferred its full range.
    public var isComplete: Bool { downloadedBytes >= length }
}
