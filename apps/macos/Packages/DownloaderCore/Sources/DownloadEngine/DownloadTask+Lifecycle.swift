import Foundation
import DownloadModels
import DownloadPersistence

extension DownloadTask {
    func refreshDestination(using scope: SecurityScope) async throws {
        guard scope.hasBookmark else { return }
        guard let path = scope.resolvedPath(for: download.destinationDirectoryPath) else {
            throw DownloadError.fileSystem(reason: "restore the original download folder to its saved location, then retry")
        }
        let bookmark = try scope.refreshedBookmark()
        guard path != download.destinationDirectoryPath || bookmark != nil else { return }
        download.destinationDirectoryPath = path
        if let bookmark { download.destinationBookmark = bookmark }
        await persist()
        emit(.downloadUpdated(download))
    }

    /// Persisted ranges must cover the resource exactly once. Overlap, gaps or duplicate IDs can
    /// corrupt output or trap the progress dictionary even when each segment is valid on its own.
    func hasValidSegmentLayout() -> Bool {
        var nextOffset: Int64 = 0
        var ids = Set<Int>()
        for segment in download.segments.sorted(by: { $0.start < $1.start }) {
            guard segment.id >= 0, ids.insert(segment.id).inserted,
                  segment.start == nextOffset, segment.end >= segment.start, segment.end < .max,
                  segment.downloadedBytes >= 0,
                  segment.downloadedBytes <= segment.end - segment.start + 1 else { return false }
            nextOffset = segment.end + 1
        }
        if let total = download.totalBytes {
            return nextOffset == total && (download.supportsResume || download.segments.count == 1)
        }
        return download.segments.count == 1 && nextOffset == .max && !download.supportsResume
    }

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
