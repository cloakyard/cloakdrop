import Foundation
import DownloadModels

/// Pure segmentation math: splits a known-size resource into balanced, contiguous,
/// non-overlapping byte ranges. Kept free of I/O so it can be exhaustively unit-tested.
public enum SegmentPlanner {

    /// Pick a connection count for a known-size, range-capable resource.
    ///
    /// An explicit per-download choice wins (subject to the hard limits). In automatic mode the
    /// configured default remains the baseline for ordinary files, while very large resources ramp
    /// toward `maximumSegments`. The size capacity is always authoritative, so no plan creates
    /// segments smaller than `minimumSegmentSize`.
    public static func recommendedSegmentCount(
        totalBytes: Int64,
        requestedSegments: Int?,
        preferredSegments: Int,
        maximumSegments: Int,
        minimumSegmentSize: Int64
    ) -> Int {
        guard totalBytes > 0 else { return 1 }

        let minimum = max(1, minimumSegmentSize)
        let capacityBySize = max(1, Int(totalBytes / minimum))
        let hardMaximum = max(1, min(maximumSegments, capacityBySize))

        if let requestedSegments {
            return min(hardMaximum, max(1, requestedSegments))
        }

        let preferred = min(hardMaximum, max(1, preferredSegments))

        // Keep at least ~16 MiB (and at least 16 configured minimum-size units) behind each
        // automatically-added connection. This avoids connection/TLS overhead on modest files but
        // lets a large image, archive, or installer use the full configured ceiling.
        let scaledMinimum = minimum > Int64.max / 16 ? Int64.max : minimum * 16
        let targetBytesPerConnection = max(Int64(16 * 1024 * 1024), scaledMinimum)
        let sizeDriven = Int(min(
            Int64(hardMaximum),
            1 + (totalBytes - 1) / targetBytesPerConnection
        ))
        return min(hardMaximum, max(preferred, sizeDriven))
    }

    /// Plan the segments for a download.
    ///
    /// - Parameters:
    ///   - totalBytes: Total size of the resource. Must be `> 0`.
    ///   - requestedSegments: Desired number of parallel connections.
    ///   - minimumSegmentSize: Smallest worthwhile segment; the plan never produces a
    ///     segment smaller than this (except a lone segment for a tiny file).
    /// - Returns: Contiguous segments covering `[0, totalBytes - 1]`, ordered by offset.
    ///   Always at least one segment.
    public static func plan(
        totalBytes: Int64,
        requestedSegments: Int,
        minimumSegmentSize: Int64
    ) -> [DownloadSegment] {
        guard totalBytes > 0 else {
            return [DownloadSegment(id: 0, start: 0, end: 0)]
        }

        // How many segments can we make without any falling below the minimum size?
        let minSize = max(1, minimumSegmentSize)
        let capacityBySize = max(1, Int(totalBytes / minSize))
        let count = max(1, min(requestedSegments, capacityBySize))

        // Distribute bytes as evenly as possible: the first `remainder` segments get one extra.
        let base = totalBytes / Int64(count)
        let remainder = totalBytes % Int64(count)

        var segments: [DownloadSegment] = []
        segments.reserveCapacity(count)
        var cursor: Int64 = 0
        for index in 0..<count {
            let extra: Int64 = index < Int(remainder) ? 1 : 0
            let length = base + extra
            let start = cursor
            let end = start + length - 1
            segments.append(DownloadSegment(id: index, start: start, end: end))
            cursor = end + 1
        }
        return segments
    }

    /// Re-plan only the *unfinished* tail of a slow/stalled segment by splitting its
    /// remaining range in two, without disturbing bytes already written. A building block for
    /// dynamic re-segmentation used by the live transfer's tail work-stealing path. Returns `nil`
    /// if the remainder is too small to split.
    ///
    /// - Returns: `(updated, new)` where `updated` keeps the first half of the remaining
    ///   range and `new` (with id `newSegmentID`) takes the second half.
    public static func split(
        _ segment: DownloadSegment,
        newSegmentID: Int,
        minimumSegmentSize: Int64
    ) -> (updated: DownloadSegment, new: DownloadSegment)? {
        let remaining = segment.remainingBytes
        let minimum = max(1, minimumSegmentSize)
        // Division avoids overflowing when a corrupt/hostile settings blob contains Int64.max.
        guard remaining / 2 >= minimum else { return nil }

        let splitPoint = segment.currentOffset + remaining / 2
        // First half: from current offset up to splitPoint-1, plus the bytes already done.
        let updated = DownloadSegment(
            id: segment.id,
            start: segment.start,
            end: splitPoint - 1,
            downloadedBytes: segment.downloadedBytes
        )
        let new = DownloadSegment(
            id: newSegmentID,
            start: splitPoint,
            end: segment.end,
            downloadedBytes: 0
        )
        return (updated, new)
    }
}
