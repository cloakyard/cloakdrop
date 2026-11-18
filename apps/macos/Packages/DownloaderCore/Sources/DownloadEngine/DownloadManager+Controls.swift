import Foundation
import DownloadModels

extension DownloadManager {
    // MARK: - Lifecycle controls

    public func pause(id: UUID) async {
        guard !editingDownloads.contains(id) else { return }
        autoPaused.remove(id)
        manualPauseRevisions[id, default: 0] += 1
        removeFromPriority(id)
        await pauseTransfer(id: id)
        scheduleAllQueues()
    }

    func pauseTransfer(id: UUID) async {
        guard let download = downloads[id] else { return }
        if let task = tasks[id] {
            let handle = handles[id]
            await task.requestStop(.pause)
            handle?.cancel()
            // Wait for the task to fully unwind (its terminal ".paused" persist runs here) before
            // returning. Otherwise a resume() issued in the gap sets .queued, then the task's late
            // taskFinished() clobbers it back to .paused and the download is stuck. Mirrors cancel().
            await handle?.value
        } else if download.status.isActive || download.status == .scheduled {
            update(id: id) { $0.status = .paused }
        }
    }

    public func resume(id: UUID) async {
        guard !editingDownloads.contains(id) else { return }
        guard let download = downloads[id], !download.status.isTerminal else { return }
        autoPaused.remove(id)
        update(id: id) { $0.status = .queued }
        scheduleQueue(download.queueID)
    }

    public func cancel(id: UUID) async {
        guard !editingDownloads.contains(id) else { return }
        autoPaused.remove(id)
        removeFromPriority(id)
        defer { scheduleAllQueues() }
        guard let download = downloads[id] else { return }
        if let task = tasks[id] {
            let handle = handles[id]
            await task.requestStop(.cancel)
            handle?.cancel()
            // Wait for the task to fully unwind (its terminal persist runs here) so a later
            // remove() can't race with a resurrecting save.
            await handle?.value
        } else {
            SegmentedFileWriter.discardPartData(for: download)
            update(id: id) { $0.status = .canceled }
        }
    }

    public func remove(id: UUID, deleteFile: Bool) async {
        guard !editingDownloads.contains(id) else { return }
        autoPaused.remove(id)
        removeFromPriority(id)
        defer { scheduleAllQueues() }
        guard let initialDownload = downloads[id] else { return }
        // Stop any running transfer and wait for it to fully unwind (its terminal save runs
        // here) so it can't re-create the row after we delete it.
        if let task = tasks[id] {
            let handle = handles[id]
            await task.requestStop(.cancel)
            handle?.cancel()
            await handle?.value
        }
        // Finalization may have won the race before cancellation and remapped the destination (for
        // example into an auto-category folder). Delete from the authoritative post-unwind snapshot.
        let download = downloads[id] ?? initialDownload
        // Drop from memory, then discard files and delete from the store. We deliberately do
        // NOT route through cancel()/update(): marking a terminal download ".canceled" and
        // persisting it via a detached task would race with the delete below.
        downloads[id] = nil
        tasks[id] = nil
        handles[id] = nil
        SegmentedFileWriter.discardPartData(for: download, deleteFile: deleteFile)
        // Drain any save still queued for this id so a straggler can't re-create the row after
        // the delete.
        await pendingSaves[id]?.value
        pendingSaves[id] = nil
        try? await store.delete(id: id)
        eventContinuation.yield(.downloadRemoved(id))
    }

    public func pauseAll() async {
        // Offline transfers already have .paused status, so the active-only loop cannot clear them.
        autoPaused.removeAll()
        pendingPriorityTarget = nil
        schedulingHolds += 1
        defer { schedulingHolds -= 1; scheduleAllQueues() }
        endPriority()
        for id in downloads.keys where downloads[id]?.status.isActive == true {
            await pause(id: id)
        }
    }

    public func resumeAll() async {
        for download in downloads.values where download.status.isResumable {
            await resume(id: download.id)
        }
    }

    /// Drop every completed download from the catalog and the store. The finished files on
    /// disk are left untouched — this only clears them from the list.
    public func clearCompleted() async {
        let ids = downloads.values.filter { $0.status == .completed }.map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids {
            downloads[id] = nil
            eventContinuation.yield(.downloadRemoved(id))
        }
        try? await store.deleteCompleted()
    }

}
