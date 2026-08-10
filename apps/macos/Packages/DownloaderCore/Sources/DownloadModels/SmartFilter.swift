/// The built-in "smart" sidebar groupings. Each is a predicate over a `Download`.
public enum SmartFilter: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case all
    case downloading
    case completed
    case failed
    case scheduled

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return "All"
        case .downloading: return "Downloading"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .scheduled: return "Scheduled"
        }
    }

    public var systemImage: String {
        switch self {
        case .all: return "tray.full"
        case .downloading: return "arrow.down.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .scheduled: return "calendar"
        }
    }

    /// Whether a download belongs in this grouping.
    public func matches(_ download: Download) -> Bool {
        switch self {
        case .all:
            return true
        case .downloading:
            switch download.status {
            case .downloading, .queued, .paused: return true
            default: return false
            }
        case .completed:
            return download.status == .completed
        case .failed:
            if case .failed = download.status { return true }
            return false
        case .scheduled:
            return download.status == .scheduled
        }
    }
}
