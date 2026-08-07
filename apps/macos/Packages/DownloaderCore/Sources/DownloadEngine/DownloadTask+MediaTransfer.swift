import Foundation
import DownloadModels

extension DownloadTask {
    // MARK: Media transfer (HLS/DASH)

    /// Transfer a media plan: fetch the fMP4 init segment and any AES-128 keys, then each media
    /// segment in parallel (rate-limited, retrying on drops), decrypting as needed. Every segment
    /// lands in its own file in the `.cdparts` directory, so an interrupted grab resumes by
    /// skipping the files already on disk — the same "disk is the source of truth" invariant the
    /// file path relies on, so it survives force-quit and reboot.
    func transferMedia() async throws {
        guard let plan = download.mediaPlan else { return }
        let partDir = download.mediaPartDirectoryPath
        try FileManager.default.createDirectory(atPath: partDir, withIntermediateDirectories: true)
        let headers = download.requestHeaders

        try await fetchInitIfNeeded(plan.initSegment, named: "init.part", partDir: partDir, headers: headers)
        if plan.hasSeparateAudio {
            try await fetchInitIfNeeded(plan.audioInitSegment, named: "audio-init.part", partDir: partDir, headers: headers)
        }

        var keys: [URL: Data] = [:]
        for keyURL in plan.keyURLs {
            keys[keyURL] = try await fetchResource(url: keyURL, byteRange: nil, headers: headers)
        }

        syncMediaProgressFromDisk(plan: plan, partDir: partDir)
        await persist()
        emitMediaProgress(plan: plan)

        let remaining = mediaWorkItems(plan: plan, partDir: partDir)
            .filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard !remaining.isEmpty else { return }

        let limiters = perDownloadLimiters()
        let concurrency = max(1, min(settings.maxSegmentCount, settings.defaultSegmentCount))
        let settings = self.settings

        for batch in remaining.chunked(into: concurrency) {
            try await withThrowingTaskGroup(of: (String, Int).self) { group in
                for item in batch {
                    let path = item.path
                    let segment = item.segment
                    let key = segment.encryption.method == .aes128 ? segment.encryption.keyURL.flatMap { keys[$0] } : nil
                    group.addTask { [httpClient] in
                        let bytes = try await runMediaSegment(
                            segment: segment,
                            filePath: path,
                            key: key,
                            headers: headers,
                            httpClient: httpClient,
                            limiters: limiters,
                            settings: settings,
                            onExpectedBytes: { total in await self.recordMediaExpected(path: path, bytes: total) },
                            onBytes: { delta in await self.recordMediaBytes(path: path, delta: delta) }
                        )
                        return (path, bytes)
                    }
                }
                for try await (path, bytes) in group {
                    markMediaSegmentComplete(path: path, bytes: Int64(bytes), plan: plan)
                }
            }
        }
    }

    private struct MediaWorkItem { let segment: MediaSegment; let path: String }

    private func mediaWorkItems(plan: MediaPlan, partDir: String) -> [MediaWorkItem] {
        var items = plan.segments.map { MediaWorkItem(segment: $0, path: segmentPath(partDir, $0)) }
        for segment in (plan.audioSegments ?? []) {
            items.append(MediaWorkItem(segment: segment, path: audioSegmentPath(partDir, segment)))
        }
        return items
    }

    private func fetchInitIfNeeded(
        _ initSegment: MediaInitSegment?, named: String, partDir: String, headers: [String: String]
    ) async throws {
        guard let initSegment else { return }
        let path = (partDir as NSString).appendingPathComponent(named)
        guard !FileManager.default.fileExists(atPath: path) else { return }
        let range = initSegment.byteRange.map { $0.offset...$0.end }
        let data = try await fetchResource(url: initSegment.url, byteRange: range, headers: headers)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func syncMediaProgressFromDisk(plan: MediaPlan, partDir: String) {
        var completed = 0
        var bytes: Int64 = 0
        mediaInflight = [:]
        mediaExpected = [:]
        for item in mediaWorkItems(plan: plan, partDir: partDir) {
            if let size = fileSize(item.path) {
                completed += 1
                bytes += size
                mediaExpected[item.path] = size
            }
        }
        download.mediaCompletedSegments = completed
        download.mediaDownloadedBytes = bytes
    }

    private func recordMediaBytes(path: String, delta: Int) {
        guard delta >= 0 else {
            mediaInflight[path] = max(0, (mediaInflight[path] ?? 0) + Int64(delta))
            return
        }
        mediaInflight[path, default: 0] += Int64(delta)
        let now = clock.now
        speedSampler.add(bytes: Int64(delta), at: now)
        recordStats(at: now)
        if Self.seconds(from: lastEmit, to: now) >= 0.1, let plan = download.mediaPlan {
            lastEmit = now
            emitMediaProgress(plan: plan)
        }
    }

    private func recordMediaExpected(path: String, bytes: Int64) {
        mediaExpected[path] = bytes
    }

    func recordStats(at now: ContinuousClock.Instant) {
        let rate = speedSampler.rate(now: now)
        if rate > (download.peakBytesPerSecond ?? 0) { download.peakBytesPerSecond = rate }
        if let last = lastStatSample {
            let gap = Self.seconds(from: last, to: now)
            if gap > 0, gap < 2.0 { download.activeSeconds = (download.activeSeconds ?? 0) + gap }
        }
        lastStatSample = now
    }

    private func markMediaSegmentComplete(path: String, bytes: Int64, plan: MediaPlan) {
        download.mediaCompletedSegments += 1
        download.mediaDownloadedBytes += bytes
        mediaInflight[path] = nil
        mediaExpected[path] = bytes
        emitMediaProgress(plan: plan)
        let now = clock.now
        if Self.seconds(from: lastPersist, to: now) >= 5.0 {
            lastPersist = now
            enqueueSave(download)
        }
    }

    private func emitMediaProgress(plan: MediaPlan) {
        let inflight = mediaInflight.values.reduce(0, +)
        let totalBytes: Int64? = mediaExpected.count == plan.totalSegments
            ? mediaExpected.values.reduce(0, +)
            : nil
        emit(.progress(DownloadProgress(
            id: download.id,
            downloadedBytes: download.mediaDownloadedBytes + inflight,
            totalBytes: totalBytes,
            bytesPerSecond: speedSampler.rate(now: clock.now),
            peakBytesPerSecond: download.peakBytesPerSecond ?? 0,
            averageBytesPerSecond: download.averageBytesPerSecond ?? 0,
            completedSegments: download.mediaCompletedSegments,
            totalSegments: plan.totalSegments
        )))
    }

    /// Assemble the finished parts, remux them into a clean container when possible, and move the
    /// result into place before removing the transient part directory.
    func finalizeMedia() async throws {
        guard let plan = download.mediaPlan else { return }
        let partDir = download.mediaPartDirectoryPath

        let videoExt = assemblyExtension(initSegment: plan.initSegment, segments: plan.segments)
        let videoAssembly = (partDir as NSString).appendingPathComponent("assembly.\(videoExt)")
        try concatenate(initNamed: "init.part", segments: plan.segments,
                        pathFor: { segmentPath(partDir, $0) }, partDir: partDir, into: videoAssembly)

        var sourcePath = videoAssembly
        var container = videoExt
        if plan.hasSeparateAudio {
            let audioSegments = plan.audioSegments ?? []
            let audioExt = assemblyExtension(initSegment: plan.audioInitSegment, segments: audioSegments)
            let audioAssembly = (partDir as NSString).appendingPathComponent("assembly-audio.\(audioExt)")
            try concatenate(initNamed: "audio-init.part", segments: audioSegments,
                            pathFor: { audioSegmentPath(partDir, $0) }, partDir: partDir, into: audioAssembly)
            if let muxed = try await attemptRepackage({
                try await remuxer.mux(videoPath: videoAssembly, audioPath: audioAssembly)
            }) {
                sourcePath = muxed.outputPath
                container = muxed.fileExtension
            } else if let result = try await attemptRepackage({ try await remuxer.remux(sourcePath: videoAssembly) }) {
                sourcePath = result.outputPath
                container = result.fileExtension
            }
        } else if let result = try await attemptRepackage({ try await remuxer.remux(sourcePath: videoAssembly) }) {
            sourcePath = result.outputPath
            container = result.fileExtension
        }

        download.fileName = (download.fileName as NSString).deletingPathExtension + ".\(container)"
        download.category = FileCategory.classify(fileName: download.fileName)
        if settings.autoCategorize {
            let categoryDirectory = (download.destinationDirectoryPath as NSString)
                .appendingPathComponent(download.category.displayName)
            download.destinationDirectoryPath = categoryDirectory
        }

        try SegmentedFileWriter.finalize(partPath: sourcePath, destinationPath: download.destinationFilePath)
        try? FileManager.default.removeItem(atPath: partDir)

        if settings.applyQuarantine {
            Quarantine.apply(
                toPath: download.destinationFilePath,
                sourceURL: download.url,
                originURL: download.requestHeaders["Referer"].flatMap(URL.init(string:))
            )
        }
        await writeSubtitleSidecars(plan.subtitles ?? [], headers: download.requestHeaders)
        download.totalBytes = fileSize(download.destinationFilePath)
        download.mediaDownloadedBytes = download.totalBytes ?? download.mediaDownloadedBytes
    }

    private func attemptRepackage(_ attempt: () async throws -> RemuxResult) async throws -> RemuxResult? {
        do {
            return try await attempt()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    private func assemblyExtension(initSegment: MediaInitSegment?, segments: [MediaSegment]) -> String {
        if initSegment != nil { return "mp4" }
        let ext = segments.first?.url.pathExtension.lowercased() ?? ""
        return ext.isEmpty ? "mp4" : ext
    }

    private func concatenate(
        initNamed initName: String, segments: [MediaSegment],
        pathFor: (MediaSegment) -> String, partDir: String, into assemblyPath: String
    ) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: partDir) {
            try fileManager.createDirectory(atPath: partDir, withIntermediateDirectories: true)
        }
        try? fileManager.removeItem(atPath: assemblyPath)
        guard fileManager.createFile(atPath: assemblyPath, contents: nil),
              let output = FileHandle(forWritingAtPath: assemblyPath) else {
            throw DownloadError.fileSystem(reason: "Could not open \(assemblyPath) for assembly.")
        }
        defer { try? output.close() }

        func append(_ path: String) throws {
            guard let input = FileHandle(forReadingAtPath: path) else {
                throw DownloadError.fileSystem(reason: "Missing media part \(path).")
            }
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
        }

        let initPath = (partDir as NSString).appendingPathComponent(initName)
        if fileManager.fileExists(atPath: initPath) { try append(initPath) }
        for segment in segments { try append(pathFor(segment)) }
    }

    private func segmentPath(_ partDir: String, _ segment: MediaSegment) -> String {
        (partDir as NSString).appendingPathComponent("seg-\(segment.id).part")
    }

    private func audioSegmentPath(_ partDir: String, _ segment: MediaSegment) -> String {
        (partDir as NSString).appendingPathComponent("audio-\(segment.id).part")
    }

    private func fileSize(_ path: String) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
    }

    func fetchResource(url: URL, byteRange: ClosedRange<Int64>?, headers: [String: String]) async throws -> Data {
        let (_, stream) = try await httpClient.stream(HTTPDownloadRequest(url: url, headers: headers, byteRange: byteRange))
        var data = Data()
        for try await chunk in stream { data.append(chunk) }
        return data
    }
}
