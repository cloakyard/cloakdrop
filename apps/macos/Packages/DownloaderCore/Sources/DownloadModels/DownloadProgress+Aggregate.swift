import Foundation

extension DownloadProgress {
    /// Equal-weight mean of the currently transferring downloads' completion fractions.
    /// Live snapshots take precedence over persisted state, including media segment progress.
    /// If any active transfer is indeterminate, the combined completion is indeterminate too.
    /// Queued, paused and finished downloads do not contribute.
    public static func aggregateFraction(
        downloads: [Download],
        progress: (UUID) -> DownloadProgress?
    ) -> Double? {
        var sum = 0.0
        var count = 0
        for download in downloads where download.status == .downloading {
            let fraction: Double?
            if let live = progress(download.id) {
                fraction = live.fractionCompleted
            } else {
                fraction = download.fractionCompleted
            }
            guard let fraction, fraction.isFinite else { return nil }
            sum += min(1, max(0, fraction))
            count += 1
        }
        return count > 0 ? sum / Double(count) : nil
    }
}
