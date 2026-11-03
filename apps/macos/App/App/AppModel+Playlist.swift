import Foundation
import DownloadModels
import DownloadEngine

extension AppModel {
    func readPlaylist(_ url: URL) async throws -> MediaPlaylist {
        guard let mediaExtractor else { throw MediaExtractionError.toolUnavailable }
        return try await mediaExtractor.playlist(pageURL: url)
    }

    func importPlaylist(_ playlist: MediaPlaylist, selectedIDs: Set<Int>, selection: MediaPageSelection,
                        directory: URL, bookmark: Data?) async throws {
        try await manager.addPlaylist(playlist, selectedIDs: selectedIDs, selection: selection,
                                      directory: directory, bookmark: bookmark)
    }

    static func playlistMessage(_ error: any Error) -> String {
        if let extraction = error as? MediaExtractionError { return friendlyExtractionMessage(extraction) }
        return downloadEditMessage(error)
    }
}
