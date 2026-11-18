import AppKit
import DownloadModels

extension AppModel {
    func moveDownload(_ download: Download) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Move Download")
        panel.message = String(localized: "Choose a folder for the saved data. The download will remain paused after moving.")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                guard self.movingDownloadIDs.insert(download.id).inserted else { return }
                defer { self.movingDownloadIDs.remove(download.id) }
                do {
                    let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: [.pathKey])
                    await self.manager.pause(id: download.id)
                    try await self.manager.moveDownload(id: download.id, to: url, bookmark: bookmark)
                } catch { self.downloadOperationError = Self.downloadEditMessage(error) }
            }
        }
    }

    func finishFirst(_ id: UUID) {
        Task {
            do { try await manager.finishFirst(id: id) } catch { downloadOperationError = Self.downloadEditMessage(error) }
        }
    }

    func stopFinishingFirst() { Task { await manager.stopFinishingFirst() } }

    func repairDownload(_ id: UUID, url: URL, restart: Bool) async throws {
        try await manager.repairDownload(id: id, replacementURL: url, restart: restart)
    }

    static func downloadEditMessage(_ error: any Error) -> String {
        if let error = error as? DownloadError { return error.userMessage }
        guard let error = error as? DownloadEditError else { return error.localizedDescription }
        switch error {
        case .unavailable: return String(localized: "Pause the download before changing it.")
        case .invalidURL: return String(localized: "Enter a valid download URL without embedded credentials.")
        case .restartRequired:
            return String(localized: "The replacement could not be matched to your saved data. Restart from the beginning?")
        case .folderUnavailable: return String(localized: "The download folder is unavailable. Restore access and try again.")
        case .missingPartialData: return String(localized: "The saved download data is missing. Restart from the beginning?")
        case .destinationOccupied: return String(localized: "The destination already contains download data with this name.")
        }
    }
}
