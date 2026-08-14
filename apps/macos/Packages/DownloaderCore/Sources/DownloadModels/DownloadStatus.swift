/// The lifecycle state of a download.
///
/// `failed` carries a user-presentable reason so the UI never has to guess why a
/// transfer stopped. All cases are `Sendable` so status can cross actor boundaries.
public enum DownloadStatus: Sendable, Hashable, Codable {
    /// Waiting in a queue for a free concurrency slot.
    case queued
    /// Actively transferring bytes.
    case downloading
    /// Paused by the user; resumable via HTTP Range.
    case paused
    /// Finished and (if a checksum was provided) verified.
    case completed
    /// Stopped by an error. The associated value is a stable, human-readable reason.
    case failed(reason: String)
    /// Waiting for a scheduled start time.
    case scheduled
    /// Canceled by the user. Partial data may be discarded.
    case canceled

    /// Whether the engine considers this download "active" for concurrency accounting.
    public var isActive: Bool {
        switch self {
        case .downloading, .queued: return true
        default: return false
        }
    }

    /// Whether a paused/failed download can be resumed.
    public var isResumable: Bool {
        switch self {
        case .paused, .failed: return true
        default: return false
        }
    }

    /// Whether the download has reached a terminal, no-further-work state.
    public var isTerminal: Bool {
        switch self {
        case .completed, .canceled: return true
        default: return false
        }
    }

    /// Stable identifier used for persistence and grouping, independent of associated values.
    public var rawKind: String {
        switch self {
        case .queued: return "queued"
        case .downloading: return "downloading"
        case .paused: return "paused"
        case .completed: return "completed"
        case .failed: return "failed"
        case .scheduled: return "scheduled"
        case .canceled: return "canceled"
        }
    }
}
