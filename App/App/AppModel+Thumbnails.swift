import Foundation
import DownloadModels
import DownloadEngine

/// Poster-frame thumbnails for completed video grabs. Rendered lazily — the moment a grab finishes
/// (from `apply`) or when a completed row first appears (its `.task`) — via the engine's UI-agnostic
/// `MediaThumbnailer`, cached as JPEGs in the app's Caches container so they survive relaunch, and
/// surfaced to the row/inspector. Audio-only grabs have no frame to sample and keep the file glyph.
extension AppModel {
    /// The cached thumbnail for a download, if one has been generated yet.
    func thumbnailURL(for download: Download) -> URL? { mediaThumbnails[download.id] }

    /// Ensure a thumbnail exists for a completed video grab: reuse the on-disk cache when present
    /// (surviving relaunch), otherwise render one off the main actor and cache it. A no-op for
    /// non-media, unfinished, already-cached, or in-flight downloads.
    func ensureThumbnail(for download: Download) {
        guard download.isMedia, download.status == .completed else { return }
        guard mediaThumbnails[download.id] == nil, !thumbnailsInFlight.contains(download.id) else { return }

        let cacheURL = Self.thumbnailCacheURL(for: download.id)
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            mediaThumbnails[download.id] = cacheURL
            return
        }

        thumbnailsInFlight.insert(download.id)
        let fileURL = URL(fileURLWithPath: download.destinationFilePath)
        let id = download.id
        Task { [weak self] in
            let data = try? await MediaThumbnailer.generateJPEG(for: fileURL)
            if let data { try? data.write(to: cacheURL, options: .atomic) }
            await MainActor.run {
                self?.thumbnailsInFlight.remove(id)
                if data != nil { self?.mediaThumbnails[id] = cacheURL }
            }
        }
    }

    /// `~/Library/Caches/<container>/Thumbnails/<id>.jpg` — inside the sandbox container, so it's
    /// writable and swept by the system under cache pressure (regenerated on demand if evicted).
    private static func thumbnailCacheURL(for id: UUID) -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(id.uuidString).jpg")
    }
}
