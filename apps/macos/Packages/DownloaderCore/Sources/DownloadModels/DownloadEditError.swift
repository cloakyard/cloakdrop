import Foundation

/// Recoverable failures when changing an existing download. The app supplies localized guidance.
public enum DownloadEditError: Error, Sendable, Equatable {
    case unavailable
    case invalidURL
    case restartRequired
    case folderUnavailable
    case missingPartialData
    case destinationOccupied
}
