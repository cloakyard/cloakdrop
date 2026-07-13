import Foundation

/// Pure decision helper for the destination-disk free-space preflight. The actual capacity query
/// (`URLResourceValues.volumeAvailableCapacityForImportantUsage`) lives in the engine; this keeps
/// the "is there room?" rule I/O-free and unit-tested.
public enum DiskSpace {
    /// Whether a volume with `available` free bytes can't hold `needed` more bytes. Best-effort:
    /// when `available` is unknown (`nil`), returns `false` so an unmeasurable disk never blocks a
    /// download that might well fit.
    public static func isInsufficient(needed: Int64, available: Int64?) -> Bool {
        guard let available else { return false }
        return needed > available
    }
}
