import Foundation
import DownloadModels
import DownloadPersistence

extension DownloadTask {
    func handleStop() async -> Download {
        switch stopReason ?? .pause {
        case .cancel:
            download.status = .canceled
            SegmentedFileWriter.discardPartData(for: download)
        case .pause:
            download.status = .paused
        }
        await persist()
        emit(.downloadUpdated(download))
        return download
    }

    func transition(to status: DownloadStatus) async {
        download.status = status
        await persist()
        emit(.downloadUpdated(download))
    }

    /// Persist a throttled mid-transfer snapshot after any save already queued (fire-and-forget).
    func enqueueSave(_ snapshot: Download) {
        pendingSave = Task { [store, previous = pendingSave] in
            await previous?.value
            try? await store.save(snapshot)
        }
    }

    func persist() async {
        enqueueSave(download)
        await pendingSave?.value
    }

    static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        start.seconds(to: end)
    }

    static func message(for error: any Error) -> String {
        (error as? DownloadError)?.userMessage ?? error.localizedDescription
    }
}
