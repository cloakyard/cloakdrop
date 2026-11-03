import Foundation
import DownloadModels

extension DownloadManager {
    /// Temporarily dedicate scheduling to one item across all queues. Queued work stays queued;
    /// only transfers that were actually running are stopped. User-paused items are never adopted.
    public func finishFirst(id: UUID) async throws {
        guard let target = downloads[id], !target.status.isTerminal, target.status != .scheduled,
              !editingDownloads.contains(id), schedulingHolds == 0 else { throw DownloadEditError.unavailable }
        schedulingHolds += 1
        pendingPriorityTarget = id
        defer { pendingPriorityTarget = nil; schedulingHolds -= 1; scheduleAllQueues() }
        endPriority()
        // Stop the target too: it must not finish while peers are still being paused, otherwise a
        // late peer stop could land after restoration and strand that peer in the paused state.
        if tasks[id] != nil { await pauseTransfer(id: id) }
        guard pendingPriorityTarget == id, let current = downloads[id], !current.status.isTerminal else { return }
        let held = Set(downloads.values.filter { $0.id != id && $0.status.isActive }.map(\.id))
        let pauseRevisions = manualPauseRevisions
        settings.downloadPriority = DownloadPriority(downloadID: id, heldDownloadIDs: held)
        priorityChanged()
        await pendingSettingsSave?.value
        for peer in held {
            guard pendingPriorityTarget == id, settings.downloadPriority?.downloadID == id else { return }
            if tasks[peer] != nil { await pauseTransfer(id: peer) }
            if manualPauseRevisions[peer, default: 0] == pauseRevisions[peer, default: 0],
               downloads[peer]?.status == .paused {
                update(id: peer) { $0.status = .queued }
            }
        }
        guard settings.downloadPriority?.downloadID == id,
              let ready = downloads[id], !ready.status.isTerminal else { return }
        if tasks[id] == nil { update(id: id) { $0.status = .queued } }
    }

    public func stopFinishingFirst() {
        pendingPriorityTarget = nil
        endPriority()
        scheduleAllQueues()
    }

    func removeFromPriority(_ id: UUID) {
        if pendingPriorityTarget == id { pendingPriorityTarget = nil }
        guard var priority = settings.downloadPriority else { return }
        if priority.downloadID == id {
            endPriority()
        } else if priority.heldDownloadIDs.remove(id) != nil {
            settings.downloadPriority = priority
            priorityChanged()
        }
    }

    func endPriority() {
        guard let priority = settings.downloadPriority else { return }
        settings.downloadPriority = nil
        for id in priority.heldDownloadIDs where downloads[id]?.status == .paused && !editingDownloads.contains(id) {
            update(id: id) { $0.status = .queued }
        }
        priorityChanged()
    }

    func restorePriorityAfterLaunch() {
        guard let priority = settings.downloadPriority else { return }
        if !settings.resumeDownloadsOnLaunch {
            settings.downloadPriority = nil
            priorityChanged()
            return
        }
        for id in priority.heldDownloadIDs where downloads[id]?.status == .paused {
            update(id: id) { $0.status = .queued }
        }
        guard let target = downloads[priority.downloadID], target.status.isActive else {
            endPriority()
            return
        }
    }

    func priorityChanged() {
        persistSettings()
        eventContinuation.yield(.settingsChanged(settings))
    }

    func persistSettings() {
        let snapshot = settingsForPersistence(settings)
        pendingSettingsSave = Task { [store, previous = pendingSettingsSave] in
            await previous?.value
            try? await store.save(settings: snapshot)
        }
    }
}
