import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadEngine

private struct FirstBytesTimeout: Error {}

/// Deterministically wait until the engine has reported real transferred bytes for `id`, then return.
/// A robust replacement for a fixed `Task.sleep` before pausing mid-flight: it observes the actual
/// progress stream, so a busy machine can't make a test pause before any bytes have landed. Times out
/// (throwing) rather than hanging if progress never arrives.
func awaitFirstBytes(_ manager: DownloadManager, _ id: UUID, timeout: Duration = .seconds(15)) async throws {
    try await awaitProgress(manager, id, timeout: timeout) { $0.downloadedBytes > 0 }
}

/// Wait until a *whole media segment* has completed. Distinct from `awaitFirstBytes`: media progress
/// events count in-flight bytes live, so bytes > 0 no longer implies a finished segment.
func awaitFirstSegment(_ manager: DownloadManager, _ id: UUID, timeout: Duration = .seconds(15)) async throws {
    try await awaitProgress(manager, id, timeout: timeout) { ($0.completedSegments ?? 0) > 0 }
}

private func awaitProgress(
    _ manager: DownloadManager, _ id: UUID, timeout: Duration,
    where predicate: @escaping @Sendable (DownloadProgress) -> Bool
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            for await event in manager.progressEvents {
                if case .progress(let progress) = event, progress.id == id, predicate(progress) { return }
            }
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw FirstBytesTimeout()
        }
        try await group.next()   // whichever finishes first: condition met (returns) or timeout (throws)
        group.cancelAll()
    }
}
