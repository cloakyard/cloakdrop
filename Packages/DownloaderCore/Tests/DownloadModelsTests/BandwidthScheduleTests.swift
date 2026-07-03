import Foundation
import Testing
@testable import DownloadModels

@Suite("Bandwidth schedule")
struct BandwidthScheduleTests {
    @Test("A disabled schedule never contains any minute")
    func disabledNeverContains() {
        let s = BandwidthSchedule(isEnabled: false, startMinute: 9 * 60, endMinute: 17 * 60)
        #expect(s.contains(minuteOfDay: 10 * 60) == false)
    }

    @Test("A same-day window is half-open [start, end)")
    func sameDayWindow() {
        let s = BandwidthSchedule(isEnabled: true, startMinute: 9 * 60, endMinute: 17 * 60)
        #expect(s.contains(minuteOfDay: 9 * 60))          // start is inclusive
        #expect(s.contains(minuteOfDay: 12 * 60))
        #expect(s.contains(minuteOfDay: 17 * 60) == false) // end is exclusive
        #expect(s.contains(minuteOfDay: 8 * 60 + 59) == false)
    }

    @Test("A window that wraps past midnight covers both sides of 00:00")
    func wrapsMidnight() {
        let s = BandwidthSchedule(isEnabled: true, startMinute: 22 * 60, endMinute: 6 * 60)
        #expect(s.contains(minuteOfDay: 23 * 60))     // before midnight
        #expect(s.contains(minuteOfDay: 2 * 60))      // after midnight
        #expect(s.contains(minuteOfDay: 12 * 60) == false)  // midday is outside
    }

    @Test("effectiveLimit uses the window limit inside, the base outside")
    func effectiveLimitResolves() {
        // Throttle to 1 MB/s 09:00–17:00; unlimited (base nil) otherwise.
        let s = BandwidthSchedule(isEnabled: true, startMinute: 9 * 60, endMinute: 17 * 60,
                                  limitBytesPerSecond: 1_000_000)
        #expect(BandwidthSchedule.effectiveLimit(schedule: s, baseLimit: nil, minuteOfDay: 12 * 60) == 1_000_000)
        #expect(BandwidthSchedule.effectiveLimit(schedule: s, baseLimit: nil, minuteOfDay: 20 * 60) == nil)

        // "Unlimited overnight": base is a limit, the window lifts it.
        let overnight = BandwidthSchedule(isEnabled: true, startMinute: 0, endMinute: 6 * 60,
                                          limitBytesPerSecond: nil)
        #expect(BandwidthSchedule.effectiveLimit(schedule: overnight, baseLimit: 500_000, minuteOfDay: 2 * 60) == nil)
        #expect(BandwidthSchedule.effectiveLimit(schedule: overnight, baseLimit: 500_000, minuteOfDay: 12 * 60) == 500_000)
    }
}
