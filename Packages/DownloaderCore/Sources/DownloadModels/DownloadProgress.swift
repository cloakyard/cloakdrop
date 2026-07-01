import Foundation

/// An ephemeral progress snapshot streamed from the engine to the UI.
///
/// Unlike `Download`, this is never persisted — it carries the fast-moving metrics
/// (instantaneous speed, ETA) that would otherwise thrash the database.
public struct DownloadProgress: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let downloadedBytes: Int64
    public let totalBytes: Int64?
    /// Instantaneous transfer rate in bytes/sec (smoothed by the engine).
    public let bytesPerSecond: Double
    /// Per-segment downloaded byte counts, for the inspector's segment view.
    public let segmentBytes: [Int: Int64]

    /// For a media (HLS/DASH) grab, how many of `totalSegments` have finished — the basis for the
    /// fraction, since the total byte size usually isn't known up front. `nil` for file downloads.
    public let completedSegments: Int?
    public let totalSegments: Int?

    public init(
        id: UUID,
        downloadedBytes: Int64,
        totalBytes: Int64?,
        bytesPerSecond: Double,
        segmentBytes: [Int: Int64] = [:],
        completedSegments: Int? = nil,
        totalSegments: Int? = nil
    ) {
        self.id = id
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.segmentBytes = segmentBytes
        self.completedSegments = completedSegments
        self.totalSegments = totalSegments
    }

    /// Fraction complete in `0...1`, or `nil` if it can't be determined. Media uses the segment
    /// share; a file download uses bytes over the total.
    public var fractionCompleted: Double? {
        if let completedSegments, let totalSegments, totalSegments > 0 {
            return min(1.0, Double(completedSegments) / Double(totalSegments))
        }
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1.0, Double(downloadedBytes) / Double(totalBytes))
    }

    /// Estimated time remaining in seconds, or `nil` if it cannot be computed.
    public var estimatedTimeRemaining: TimeInterval? {
        guard let totalBytes, bytesPerSecond > 1 else { return nil }
        let remaining = Double(totalBytes - downloadedBytes)
        guard remaining > 0 else { return 0 }
        return remaining / bytesPerSecond
    }
}
