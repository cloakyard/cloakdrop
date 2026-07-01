import Foundation

/// A named queue that bounds how many of its downloads run concurrently.
///
/// Every download belongs to exactly one queue. The default queue always exists and
/// cannot be deleted. Ordering within a queue is explicit (`order`) so the UI can
/// support drag-to-reorder.
public struct DownloadQueue: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    /// Maximum number of simultaneously-active downloads in this queue.
    public var maxConcurrentDownloads: Int
    /// Sort position among queues in the sidebar.
    public var order: Int
    /// Whether this is the built-in default queue (not user-deletable).
    public let isDefault: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        maxConcurrentDownloads: Int = 4,
        order: Int = 0,
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.maxConcurrentDownloads = max(1, maxConcurrentDownloads)
        self.order = order
        self.isDefault = isDefault
    }

    /// Stable identifier for the built-in default queue.
    public static let defaultQueueID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// The built-in default queue every fresh install ships with.
    public static let makeDefault = DownloadQueue(
        id: defaultQueueID,
        name: "Main Queue",
        maxConcurrentDownloads: 4,
        order: 0,
        isDefault: true
    )
}
