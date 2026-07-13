import SwiftUI
import DownloadModels

/// UI presentation for download status — labels, SF Symbols, and tint colors. Kept in the
/// app layer so the engine model stays free of any UI framework.
extension DownloadStatus {
    var label: String {
        switch self {
        case .queued: return String(localized: "Queued")
        case .downloading: return String(localized: "Downloading")
        case .paused: return String(localized: "Paused")
        case .completed: return String(localized: "Completed")
        case .failed: return String(localized: "Failed")
        case .scheduled: return String(localized: "Scheduled")
        case .canceled: return String(localized: "Canceled")
        }
    }

    var systemImage: String {
        switch self {
        case .queued: return "clock"
        case .downloading: return "arrow.down.circle.fill"
        case .paused: return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .scheduled: return "calendar.badge.clock"
        case .canceled: return "xmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .queued, .scheduled: return .secondary
        case .downloading: return .accentColor
        case .paused: return .orange
        case .completed: return .green
        case .failed: return .red
        case .canceled: return .secondary
        }
    }
}
