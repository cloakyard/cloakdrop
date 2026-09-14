import Foundation

/// Bounds free-form settings before they reach integer storage or calendar arithmetic.
enum SettingsInput {
    static func speedLimitBytes(megabytesPerSecond: Double) -> Int64? {
        guard megabytesPerSecond.isFinite else { return nil }
        // Stay below Int64.max even after Double rounding, and clamp before multiplication.
        return Int64(min(max(0.1, megabytesPerSecond), 9_000_000_000_000) * 1_000_000)
    }

    static func time(on date: Date, minuteOfDay: Int, calendar: Calendar = .current) -> Date {
        let minute = min(max(0, minuteOfDay), 1439)
        // Wall-clock components preserve the chosen hour across daylight-saving transitions.
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: date)
            ?? calendar.startOfDay(for: date)
    }
}
