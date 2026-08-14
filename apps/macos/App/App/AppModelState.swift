import Foundation
import Observation
import DownloadModels

/// An add that matched an existing catalog item and awaits the user's duplicate decision.
struct DuplicateAdd: Identifiable, Equatable {
    let id = UUID()
    var request: DownloadRequest
    let match: DuplicateMatch

    var existingFileName: String { match.existing.fileName }
    var reason: DuplicateReason { match.reason }
    var existingIsOnDisk: Bool { match.existing.status == .completed }
}

/// Boxes high-frequency metrics so one progress tick invalidates only its download's views.
@MainActor
@Observable
final class ProgressBox {
    var value: DownloadProgress
    init(_ value: DownloadProgress) { self.value = value }
}
