import Foundation

/// swiftc App/Features/Settings/SettingsInput.swift scripts/tests/SettingsInputRegression.swift -o /tmp/settings-input-regression
@main
struct SettingsInputRegression {
    static func main() {
        precondition(SettingsInput.speedLimitBytes(megabytesPerSecond: 5) == 5_000_000)
        precondition(SettingsInput.speedLimitBytes(megabytesPerSecond: -1) == 100_000)
        precondition(SettingsInput.speedLimitBytes(megabytesPerSecond: .greatestFiniteMagnitude) == 9_000_000_000_000_000_000)
        precondition(SettingsInput.speedLimitBytes(megabytesPerSecond: .nan) == nil)
        precondition(SettingsInput.speedLimitBytes(megabytesPerSecond: .infinity) == nil)
        precondition(SettingsInput.speedLimitBytes(megabytesPerSecond: -.infinity) == nil)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for day in [DateComponents(year: 2026, month: 3, day: 8), DateComponents(year: 2026, month: 11, day: 1)] {
            let date = calendar.date(from: day)!
            for (input, expected) in [(Int.min, 0), (Int.max, 1439), (9 * 60 + 30, 9 * 60 + 30)] {
                let result = SettingsInput.time(on: date, minuteOfDay: input, calendar: calendar)
                let components = calendar.dateComponents([.hour, .minute], from: result)
                precondition(components.hour == expected / 60 && components.minute == expected % 60)
                precondition(calendar.isDate(date, inSameDayAs: result))
            }
        }
        print("Settings input regression passed")
    }
}
