import Foundation

/// A time-of-day override for the global speed limit — "throttle to 1 MB/s between 9am–5pm" or
/// "go unlimited overnight". Pure value + arithmetic; the engine ticks it and applies the resolved
/// limit to the shared global `BandwidthLimiter`. Persisted in `EngineSettings`.
///
/// The window is expressed in **minutes from local midnight** and may wrap past midnight
/// (`start = 22:00`, `end = 06:00`). Days-of-week are intentionally left out for now — a single daily
/// window covers the overwhelming majority of "quiet hours" setups without a heavier UI.
public struct BandwidthSchedule: Sendable, Hashable, Codable {
    public var isEnabled: Bool
    /// Window start, minutes from local midnight, `[0, 1440)`.
    public var startMinute: Int
    /// Window end, minutes from local midnight, `[0, 1440)`. Equal to `startMinute` means "empty".
    public var endMinute: Int
    /// The limit to apply **inside** the window, in bytes/sec. `nil` means unlimited within the window
    /// (the "unlimited overnight" case).
    public var limitBytesPerSecond: Int64?

    public init(
        isEnabled: Bool = false,
        startMinute: Int = 9 * 60,
        endMinute: Int = 17 * 60,
        limitBytesPerSecond: Int64? = 1_000_000
    ) {
        self.isEnabled = isEnabled
        self.startMinute = Self.clampMinute(startMinute)
        self.endMinute = Self.clampMinute(endMinute)
        self.limitBytesPerSecond = limitBytesPerSecond.flatMap { $0 > 0 ? $0 : nil }
    }

    private static func clampMinute(_ m: Int) -> Int { min(1439, max(0, m)) }

    /// Whether `minuteOfDay` falls inside the (enabled) window, handling windows that wrap past
    /// midnight. All three minute values are normalized to `[0, 1440)` here, so a persisted or
    /// externally-mutated out-of-range bound (which bypasses `clampMinute`) can't silently break the
    /// window.
    public func contains(minuteOfDay: Int) -> Bool {
        guard isEnabled else { return false }
        let start = Self.normalizeMinute(startMinute)
        let end = Self.normalizeMinute(endMinute)
        guard start != end else { return false }
        let m = Self.normalizeMinute(minuteOfDay)
        return start < end
            ? (m >= start && m < end)       // same-day window
            : (m >= start || m < end)        // wraps midnight
    }

    private static func normalizeMinute(_ m: Int) -> Int { ((m % 1440) + 1440) % 1440 }

    /// Resolve the effective global limit at `minuteOfDay`: the window's limit when inside it,
    /// otherwise the always-on `baseLimit`. Static so it's trivially unit-tested without a clock.
    public static func effectiveLimit(
        schedule: BandwidthSchedule?,
        baseLimit: Int64?,
        minuteOfDay: Int
    ) -> Int64? {
        if let schedule, schedule.contains(minuteOfDay: minuteOfDay) {
            return schedule.limitBytesPerSecond
        }
        return baseLimit
    }
}
