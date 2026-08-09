import Foundation
import DownloadModels

extension DownloadManager {
    // MARK: - Queue scheduling

    func scheduleAllQueues() {
        for queueID in queues.keys { scheduleQueue(queueID) }
    }

    func scheduleQueue(_ queueID: UUID) {
        guard networkReachable else { return }
        let limit = queues[queueID]?.maxConcurrentDownloads ?? 1
        var active = downloads.values.filter { $0.queueID == queueID && tasks[$0.id] != nil }.count

        let waiting = downloads.values
            .filter { $0.queueID == queueID && $0.status == .queued && tasks[$0.id] == nil }
            .sorted { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) }

        for download in waiting where active < limit {
            start(download)
            active += 1
        }
    }

    private func start(_ download: Download) {
        var starting = download
        starting.status = .downloading
        downloads[download.id] = starting

        let task = DownloadTask(
            download: starting,
            httpClient: httpClient,
            store: store,
            globalLimiter: globalLimiter,
            settings: settings,
            remuxer: remuxer,
            signatureInspector: signatureInspector,
            emit: { [eventContinuation, progressContinuation] event in
                if case .progress = event {
                    progressContinuation.yield(event)
                } else {
                    eventContinuation.yield(event)
                }
            }
        )
        tasks[download.id] = task

        let id = download.id
        handles[id] = Task { [weak self] in
            let final = await task.run()
            await self?.taskFinished(id: id, result: final)
        }
    }

    private func taskFinished(id: UUID, result: Download) async {
        downloads[id] = result
        tasks[id] = nil
        handles[id] = nil
        if result.status == .completed { enqueueRecurrence(of: result) }
        scheduleQueue(result.queueID)
        signalIfQueueDrained(after: result)
        if result.status == .completed {
            try? await store.recordDownloadedBytes(result.downloadedBytes, on: Date())
            currentStats = (try? await store.loadStats(asOf: Date())) ?? currentStats
            eventContinuation.yield(.statsChanged(currentStats))
        }
    }

    private func enqueueRecurrence(of completed: Download) {
        guard let recurrence = completed.recurrence, recurrence != .none,
              let next = recurrence.nextDate(after: Date()) else { return }

        var destination = completed.destinationDirectoryPath
        if (destination as NSString).lastPathComponent == completed.category.displayName {
            destination = (destination as NSString).deletingLastPathComponent
        }

        let order = (downloads.values.map(\.order).max() ?? -1) + 1
        var nextRun = Download(
            url: completed.url,
            fileName: completed.fileName,
            destinationDirectoryPath: destination,
            destinationBookmark: completed.destinationBookmark,
            requestedSegmentCount: completed.requestedSegmentCount,
            queueID: completed.queueID,
            requestHeaders: completed.requestHeaders,
            speedLimitBytesPerSecond: completed.speedLimitBytesPerSecond,
            username: completed.username,
            password: completed.password,
            checksum: completed.checksum,
            scheduledStart: next,
            recurrence: recurrence,
            order: order
        )
        nextRun.status = .scheduled
        downloads[nextRun.id] = nextRun
        persistOrdered(nextRun)
        eventContinuation.yield(.downloadAdded(nextRun))
    }

    private func signalIfQueueDrained(after finished: Download) {
        guard finished.status == .completed else { return }
        let hasPending = downloads.values.contains { download in
            switch download.status {
            case .downloading, .queued, .scheduled, .paused: return true
            default: return false
            }
        }
        if !hasPending { eventContinuation.yield(.allDownloadsCompleted) }
    }

    // MARK: - Time-based scheduling

    func startScheduler() {
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await self?.promoteScheduled(asOf: Date())
            }
        }
    }

    func startBandwidthScheduler() {
        bandwidthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.applyEffectiveGlobalLimit()
            }
        }
    }

    private func applyEffectiveGlobalLimit() async {
        await globalLimiter.setRate(bytesPerSecond: effectiveGlobalLimit())
    }

    func effectiveGlobalLimit(now: Date = Date()) -> Int64? {
        let minute = Self.minuteOfDay(now)
        return BandwidthSchedule.effectiveLimit(
            schedule: settings.bandwidthSchedule,
            baseLimit: settings.globalSpeedLimitBytesPerSecond,
            minuteOfDay: minute
        )
    }

    private static func minuteOfDay(_ date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    func promoteScheduled(asOf date: Date) {
        var touchedQueues = Set<UUID>()
        for download in downloads.values where download.status == .scheduled {
            if let start = download.scheduledStart, start <= date {
                update(id: download.id) { $0.status = .queued }
                touchedQueues.insert(download.queueID)
            }
        }
        for queueID in touchedQueues { scheduleQueue(queueID) }
    }

    // MARK: - Network auto-resume

    func startNetworkMonitoring() {
        monitorTask = Task { [weak self, networkMonitor] in
            for await reachable in networkMonitor.reachabilityUpdates() {
                await self?.networkChanged(reachable: reachable)
            }
        }
    }

    private func networkChanged(reachable: Bool) async {
        let wasReachable = networkReachable
        networkReachable = reachable

        if wasReachable && !reachable {
            for download in downloads.values where download.status.isActive {
                autoPaused.insert(download.id)
                await pause(id: download.id)
            }
        } else if !wasReachable && reachable {
            let toResume = autoPaused
            autoPaused.removeAll()
            for id in toResume { await resume(id: id) }
            scheduleAllQueues()
        }
    }

    // MARK: - Ordered persistence

    func update(id: UUID, _ mutate: (inout Download) -> Void) {
        guard var download = downloads[id] else { return }
        mutate(&download)
        downloads[id] = download
        persistOrdered(download)
        eventContinuation.yield(.downloadUpdated(download))
    }

    func persistOrdered(_ snapshot: Download) {
        pendingSaves[snapshot.id] = Task { [store, previous = pendingSaves[snapshot.id]] in
            await previous?.value
            try? await store.save(snapshot)
        }
    }

    func persistOrderedAndWait(_ snapshot: Download) async {
        persistOrdered(snapshot)
        await pendingSaves[snapshot.id]?.value
    }
}
