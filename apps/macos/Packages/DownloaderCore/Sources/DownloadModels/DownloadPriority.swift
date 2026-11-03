import Foundation

/// A user-started temporary scheduling override. Held IDs distinguish our pauses from user pauses
/// if the app exits between stopping a worker and returning that download to the queue.
public struct DownloadPriority: Sendable, Hashable, Codable {
    public var downloadID: UUID
    public var heldDownloadIDs: Set<UUID>

    public init(downloadID: UUID, heldDownloadIDs: Set<UUID> = []) {
        self.downloadID = downloadID
        self.heldDownloadIDs = heldDownloadIDs
    }
}
