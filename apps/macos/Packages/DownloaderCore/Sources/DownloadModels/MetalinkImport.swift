import Foundation

// Bridges a parsed Metalink document into the engine's `DownloadRequest` — the strongest mirror
// becomes the primary URL, the rest become failover `mirrors`, and the advertised name + whole-file
// checksum carry through. Keeps the Metalink→download mapping in the core (Sendable, testable) rather
// than in the app layer.

public extension DownloadRequest {
    /// Build a request from one Metalink file entry. Returns `nil` only if the entry has no usable
    /// source — the parser already drops those, so this is a safety net.
    init?(
        metalink file: MetalinkFile,
        destinationDirectoryPath: String,
        destinationBookmark: Data? = nil,
        queueID: UUID = DownloadQueue.defaultQueueID
    ) {
        let urls = file.urls
        guard let primary = urls.first else { return nil }
        self.init(
            url: primary,
            mirrors: Array(urls.dropFirst()),
            suggestedFileName: file.name,
            destinationDirectoryPath: destinationDirectoryPath,
            destinationBookmark: destinationBookmark,
            queueID: queueID,
            checksum: file.checksum
        )
    }

    /// One request per file in a parsed Metalink document, all sharing a destination and queue.
    static func requests(
        fromMetalink files: [MetalinkFile],
        destinationDirectoryPath: String,
        destinationBookmark: Data? = nil,
        queueID: UUID = DownloadQueue.defaultQueueID
    ) -> [DownloadRequest] {
        files.compactMap {
            DownloadRequest(
                metalink: $0,
                destinationDirectoryPath: destinationDirectoryPath,
                destinationBookmark: destinationBookmark,
                queueID: queueID
            )
        }
    }
}
