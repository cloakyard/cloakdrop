import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadEngine

private struct FirstBytesTimeout: Error {}

/// Deterministically wait until the engine has reported real transferred bytes for `id`, then return.
/// A robust replacement for a fixed `Task.sleep` before pausing mid-flight: it observes the actual
/// progress stream, so a busy machine can't make a test pause before any bytes have landed. Times out
/// (throwing) rather than hanging if progress never arrives. For a media grab, `downloadedBytes`
/// becomes positive once the first segment finishes, which is exactly the "some progress" signal.
func awaitFirstBytes(_ manager: DownloadManager, _ id: UUID, timeout: Duration = .seconds(15)) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            for await event in manager.progressEvents {
                if case .progress(let progress) = event, progress.id == id, progress.downloadedBytes > 0 { return }
            }
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw FirstBytesTimeout()
        }
        try await group.next()   // whichever finishes first: bytes seen (returns) or timeout (throws)
        group.cancelAll()
    }
}
