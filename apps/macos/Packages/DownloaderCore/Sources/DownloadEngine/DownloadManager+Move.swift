import Foundation
import DownloadModels

extension DownloadManager {
    /// Copy staging to the chosen volume, commit the new catalog location, then retire the old copy.
    /// The original stays usable if copying, cancellation, or database persistence fails.
    public func moveDownload(id: UUID, to directory: URL, bookmark: Data?) async throws {
        guard let original = downloads[id], original.status.isResumable, tasks[id] == nil,
              editingDownloads.insert(id).inserted else { throw DownloadEditError.unavailable }
        defer { editingDownloads.remove(id) }
        let sourceScope = SecurityScope(bookmark: original.destinationBookmark)
        let destinationScope = SecurityScope(bookmark: bookmark)
        let sourceAccess = sourceScope.start()
        let destinationAccess = destinationScope.start()
        defer { sourceScope.stop(); destinationScope.stop() }
        guard !sourceScope.hasBookmark || sourceAccess, !destinationScope.hasBookmark || destinationAccess,
              directory.isFileURL else { throw DownloadEditError.folderUnavailable }
        var source = original
        if sourceScope.hasBookmark {
            guard let path = sourceScope.resolvedPath(for: original.destinationDirectoryPath) else {
                throw DownloadEditError.folderUnavailable
            }
            source.destinationDirectoryPath = path
        }
        let destination = destinationScope.hasBookmark
            ? destinationScope.resolvedPath(for: directory.path) : directory.path
        guard let destination,
              (try? URL(fileURLWithPath: destination).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw DownloadEditError.folderUnavailable
        }
        let canonical = URL(fileURLWithPath: destination).resolvingSymlinksInPath().standardizedFileURL.path
        let oldDirectory = URL(fileURLWithPath: source.destinationDirectoryPath).resolvingSymlinksInPath().standardizedFileURL.path
        if canonical == oldDirectory { return }
        guard !canonical.hasPrefix(URL(fileURLWithPath: source.mediaPartDirectoryPath).resolvingSymlinksInPath().path + "/"),
              canonical != URL(fileURLWithPath: source.mediaPartDirectoryPath).resolvingSymlinksInPath().path else {
            throw DownloadEditError.folderUnavailable
        }
        var moved = source
        moved.destinationDirectoryPath = destination
        moved.destinationBookmark = try destinationScope.refreshedBookmark() ?? bookmark
        let occupiedStaging = Set(try FileManager.default.contentsOfDirectory(atPath: destination).compactMap { name -> String? in
            if name.hasSuffix(".cdpart") { return String(name.dropLast(7)) }
            if name.hasSuffix(".cdparts") { return String(name.dropLast(8)) }
            return nil
        })
        moved.fileName = reserveUniqueFileName(source.fileName, inDirectory: destination, additionalTakenNames: occupiedStaging)
        moved.status = .paused
        // Reserve the new name while copying off-actor. No event is emitted until the commit succeeds.
        downloads[id] = moved
        var committed = false
        defer { if !committed { downloads[id] = original } }
        let staging = try DownloadStagingMove(source: source, destination: moved)
        defer { staging.cleanTemporaryDirectory() }
        let copying = Task.detached(priority: .utility) { try staging.copy() }
        try await withTaskCancellationHandler {
            try await copying.value
            try Task.checkCancellation()
        } onCancel: { copying.cancel() }
        try staging.publish()
        do {
            await pendingSaves[id]?.value
            try Task.checkCancellation()
            try await store.save(moved)
        } catch {
            staging.removePublishedCopies()
            throw error
        }
        committed = true
        autoPaused.remove(id)
        eventContinuation.yield(.downloadUpdated(moved))
        staging.retireOriginals()
    }
}

/// All names in the temporary directory are uniquely owned by this operation. Publication uses
/// no-replacement moves; rollback never removes an unrelated file that won a destination race.
private struct DownloadStagingMove: Sendable {
    struct Paths: Sendable {
        let source: String
        let temporary: String
        let destination: String
    }
    let temporary: URL
    let pairs: [Paths]

    init(source: Download, destination: Download) throws {
        let fm = FileManager.default
        temporary = URL(fileURLWithPath: destination.destinationDirectoryPath)
            .appendingPathComponent(".download-move-\(UUID())", isDirectory: true)
        var paths = [(source.partFilePath, destination.partFilePath)]
        if source.isMedia { paths.append((source.mediaPartDirectoryPath, destination.mediaPartDirectoryPath)) }
        var found: [Paths] = []
        for (old, new) in paths where fm.fileExists(atPath: old) {
            let attributes = try fm.attributesOfItem(atPath: old)
            let expectedType: FileAttributeType = old == source.mediaPartDirectoryPath ? .typeDirectory : .typeRegular
            guard attributes[.type] as? FileAttributeType == expectedType else {
                throw DownloadEditError.missingPartialData
            }
            found.append(Paths(source: old, temporary: temporary.appendingPathComponent((new as NSString).lastPathComponent).path,
                               destination: new))
        }
        guard source.downloadedBytes == 0 || !found.isEmpty else { throw DownloadEditError.missingPartialData }
        if source.isMedia, source.mediaDownloadedBytes > 0,
           !found.contains(where: { $0.source == source.mediaPartDirectoryPath }) {
            throw DownloadEditError.missingPartialData
        }
        pairs = found
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
    }

    func copy() throws {
        for pair in pairs {
            try Task.checkCancellation()
            try FileManager.default.copyItem(atPath: pair.source, toPath: pair.temporary)
        }
    }

    func publish() throws {
        var published: [String] = []
        do {
            for pair in pairs {
                try FileManager.default.moveItem(atPath: pair.temporary, toPath: pair.destination)
                published.append(pair.destination)
            }
        } catch {
            for path in published { try? FileManager.default.removeItem(atPath: path) }
            throw error
        }
    }

    func removePublishedCopies() {
        for pair in pairs { try? FileManager.default.removeItem(atPath: pair.destination) }
    }

    func retireOriginals() {
        for pair in pairs { try? FileManager.default.removeItem(atPath: pair.source) }
    }

    func cleanTemporaryDirectory() { try? FileManager.default.removeItem(at: temporary) }
}
