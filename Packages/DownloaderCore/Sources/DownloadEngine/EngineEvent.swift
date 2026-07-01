import Foundation
import DownloadModels

/// Events the engine streams to observers (the app's view model).
///
/// Metadata changes (`added`/`updated`/`removed`) carry the full `Download` snapshot; the
/// high-frequency `progress` event carries only fast-moving metrics so the UI can update
/// bytes/speed/ETA without a database round trip.
public enum EngineEvent: Sendable {
    case downloadAdded(Download)
    case downloadUpdated(Download)
    case downloadRemoved(UUID)
    case progress(DownloadProgress)
    case queuesChanged([DownloadQueue])
    case settingsChanged(EngineSettings)
    /// Emitted when a download completes and the queue is then idle — drives the optional
    /// "quit when done" post-action.
    case allDownloadsCompleted
}
