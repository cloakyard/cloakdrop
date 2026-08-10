/// One contiguous byte range of a download, transferred over its own HTTP connection.
///
/// A segment owns the half-open byte interval `[start, end]` (inclusive `end`, matching
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

    /// Total number of bytes this segment must transfer.
    public var length: Int64 { end - start + 1 }

    /// Bytes still to be fetched for this segment.
    public var remainingBytes: Int64 { max(0, length - downloadedBytes) }

    /// The absolute offset at which the next byte should be written.
    public var currentOffset: Int64 { start + downloadedBytes }

    /// Whether this segment has transferred its full range.
    public var isComplete: Bool { downloadedBytes >= length }
}
