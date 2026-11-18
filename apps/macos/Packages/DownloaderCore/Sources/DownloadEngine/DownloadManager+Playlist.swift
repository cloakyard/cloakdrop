import Foundation
import DownloadModels

extension DownloadManager {
    /// Add selected playlist pages as durable, individually resumable downloads. Existing catalog
    /// URLs are skipped. Titles and order are fixed at import; payload resolution happens in the queue.
    @discardableResult
    public func addPlaylist(
        _ playlist: MediaPlaylist, selectedIDs: Set<Int>, selection: MediaPageSelection,
        directory: URL, bookmark: Data?, startImmediately: Bool = true
    ) async throws -> [Download] {
        guard mediaExtractor != nil else { throw MediaExtractionError.toolUnavailable }
        let scope = SecurityScope(bookmark: bookmark)
        let access = scope.start()
        defer { scope.stop() }
        guard !scope.hasBookmark || access, directory.isFileURL else { throw DownloadEditError.folderUnavailable }
        let path = scope.hasBookmark ? scope.resolvedPath(for: directory.path) : directory.path
        guard let path else { throw DownloadEditError.folderUnavailable }
        var seen = Set(downloads.values.map(\.url))
        let selected = playlist.entries.filter { entry in
            guard selectedIDs.contains(entry.id), let url = entry.pageURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                  url.user == nil, url.password == nil else { return false }
            return seen.insert(url).inserted
        }
        guard !selected.isEmpty else { return [] }
        let proposedFolder = playlistComponent(playlist.title, fallback: directory.appendingPathComponent("Playlist"))
        let folderName = reserveUniqueFileName(proposedFolder, inDirectory: path)
        let folder = URL(fileURLWithPath: path).appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        schedulingHolds += 1
        defer { schedulingHolds -= 1; scheduleAllQueues() }
        var added: [Download] = []
        for entry in selected {
            try Task.checkCancellation()
            // A save suspends the actor. Another import can claim a later page while this batch
            // waits, so recheck the live catalog immediately before reserving each record.
            guard let url = entry.pageURL, !downloads.values.contains(where: { $0.url == url }) else { continue }
            let ext = selection.quality == .audioOnly ? "m4a" : "mp4"
            let title = playlistComponent(entry.title, fallback: url)
            let name = String(format: "%03d", entry.index) + " - " + title + "." + ext
            var download = Download(
                url: url, fileName: reserveUniqueFileName(name, inDirectory: folder.path),
                destinationDirectoryPath: folder.path, destinationBookmark: bookmark,
                status: startImmediately ? .queued : .paused,
                order: (downloads.values.map(\.order).max() ?? -1) + 1
            )
            download.mediaPageSelection = selection
            downloads[download.id] = download
            do { try await store.save(download) } catch { downloads[download.id] = nil; throw error }
            eventContinuation.yield(.downloadAdded(download))
            added.append(download)
        }
        return added
    }

    private func playlistComponent(_ title: String, fallback: URL) -> String {
        var name = FileNaming.fileName(suggested: title, url: fallback)
        // Filesystem limits count UTF-8 bytes, not Swift characters. Reserve space for numbering,
        // collision suffixes, staging suffixes and the eventual media extension.
        while name.utf8.count > 180 { name.removeLast() }
        return name.isEmpty ? "Playlist" : name
    }
}
