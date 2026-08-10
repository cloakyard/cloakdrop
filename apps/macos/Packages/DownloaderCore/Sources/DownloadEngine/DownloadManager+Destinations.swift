import Foundation
import DownloadModels

extension DownloadManager {
    /// Reserve a unique output name while in the manager actor's synchronous section. The caller
    /// inserts the resulting record before its next suspension, so another concurrent add observes
    /// the reservation and receives a distinct final name and staging path.
    func reserveUniqueFileName(_ proposed: String, inDirectory directory: String) -> String {
        var directories = [directory]
        if settings.autoCategorize {
            let categoryName = FileCategory.classify(fileName: proposed).displayName
            if (directory as NSString).lastPathComponent != categoryName {
                directories.append((directory as NSString).appendingPathComponent(categoryName))
            }
        }
        let standardizedDirectories = Set(directories.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
        })
        let takenNames = Set(downloads.values.compactMap { existing -> String? in
            let existingDirectory = URL(
                fileURLWithPath: existing.destinationDirectoryPath, isDirectory: true
            ).standardizedFileURL.path
            return standardizedDirectories.contains(existingDirectory) ? existing.fileName : nil
        })
        return Self.uniqueFileName(proposed, inDirectories: directories, takenNames: takenNames)
    }

    /// Resolve, sanitize, and reserve the name for a media grab. A suggested name without a media
    /// extension is a title stem, so append the plan's initial container before de-colliding it.
    func reserveMediaFileName(for request: DownloadRequest, plan: MediaPlan) -> String {
        let proposed: String
        if let suggested = request.suggestedFileName {
            let basename = FileNaming.fileName(suggested: suggested, url: request.url)
            let ext = (basename as NSString).pathExtension.lowercased()
            let isMediaExtension = MediaSniffer.mediaExtensions.contains(ext)
                || MediaSniffer.segmentExtensions.contains(ext)
            proposed = isMediaExtension ? basename : "\(basename).\(Self.mediaContainerExtension(for: plan))"
        } else {
            proposed = Self.deriveMediaFileName(from: request.url, plan: plan)
        }
        return reserveUniqueFileName(proposed, inDirectory: request.destinationDirectoryPath)
    }
}
