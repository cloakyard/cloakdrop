import Foundation

/// How often a scheduled download repeats. `none` is a one-shot. When a recurring download
/// completes, the engine re-queues a fresh copy for the next interval.
public enum ScheduleRecurrence: String, Sendable, Codable, CaseIterable, Identifiable {
    case none, hourly, daily, weekly

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: return "Don't repeat"
        case .hourly: return "Hourly"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        }
    }

    /// Seconds between occurrences, or `nil` for a one-shot.
    public var interval: TimeInterval? {
        switch self {
        case .none: return nil
        case .hourly: return 3_600
        case .daily: return 86_400
        case .weekly: return 604_800
        }
    }

    /// The next start date after `date`, or `nil` if this isn't a repeating schedule.
    public func nextDate(after date: Date) -> Date? {
        interval.map { date.addingTimeInterval($0) }
    }
}
