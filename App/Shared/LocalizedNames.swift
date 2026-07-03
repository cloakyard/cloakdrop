import Foundation
import DownloadModels

/// Localized, user-facing names for the core domain enums.
///
/// These live in the app layer (where the String Catalog is) rather than the UI-agnostic core.
/// Crucially, `FileCategory.displayName` stays a stable English string because it's also used
/// as the on-disk category *folder name*; the UI uses `localizedName` instead so the visible
/// label translates without renaming folders.
extension FileCategory {
    var localizedName: String {
        switch self {
        case .video: return String(localized: "Video")
        case .audio: return String(localized: "Audio")
        case .document: return String(localized: "Documents")
        case .archive: return String(localized: "Archives")
        case .program: return String(localized: "Programs")
        case .image: return String(localized: "Images")
        case .other: return String(localized: "Other")
        }
    }
}

extension SmartFilter {
    var localizedName: String {
        switch self {
        case .all: return String(localized: "All")
        case .downloading: return String(localized: "Downloading")
        case .completed: return String(localized: "Completed")
        case .failed: return String(localized: "Failed")
        case .scheduled: return String(localized: "Scheduled")
        }
    }
}

extension ScheduleRecurrence {
    var localizedLabel: String {
        switch self {
        case .none: return String(localized: "Don't repeat")
        case .hourly: return String(localized: "Hourly")
        case .daily: return String(localized: "Daily")
        case .weekly: return String(localized: "Weekly")
        }
    }
}

extension SchedulerPostAction {
    var localizedLabel: String {
        switch self {
        case .none: return String(localized: "Do nothing")
        case .notify: return String(localized: "Show a notification")
        case .quit: return String(localized: "Quit CloakDrop")
        case .runShortcut: return String(localized: "Run a Shortcut")
        }
    }
}

extension ProxyConfiguration.Mode {
    var localizedLabel: String {
        switch self {
        case .system: return String(localized: "Use system proxy")
        case .direct: return String(localized: "Direct connection (no proxy)")
        case .manual: return String(localized: "Manual configuration")
        }
    }
}
