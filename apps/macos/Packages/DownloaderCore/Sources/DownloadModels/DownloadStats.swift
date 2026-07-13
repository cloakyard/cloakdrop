import Foundation

/// Lifetime download totals the app shows in Settings ▸ Stats. Pure counters — the playful tier
/// names, icons, and thresholds are a presentation concern and live in the app layer, not here.
///
/// Bytes are accumulated once per *completed* download (see `DownloadStore.recordDownloadedBytes`),
/// bucketed by the day it finished, so today's / this month's / all-time totals are all derivable.
public struct DownloadStats: Sendable, Equatable, Codable {
    /// Bytes from downloads completed today (the user's local calendar day).
    public let todayBytes: Int64
    /// Bytes from downloads completed in the current calendar month — the window the top badge uses.
    public let monthBytes: Int64
    /// Bytes from every completed download since install (or the last reset).
    public let allTimeBytes: Int64

    public init(todayBytes: Int64 = 0, monthBytes: Int64 = 0, allTimeBytes: Int64 = 0) {
        self.todayBytes = todayBytes
        self.monthBytes = monthBytes
        self.allTimeBytes = allTimeBytes
    }

    /// The zero state — before anything has been downloaded, or right after a reset.
    public static let empty = DownloadStats()
}
