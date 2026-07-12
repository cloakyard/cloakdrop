import Foundation

/// Centralized, locale-aware formatting for byte sizes, speeds, and durations.
enum Format {
    /// e.g. "1.2 GB". Returns "—" for unknown sizes.
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return value.formatted(.byteCount(style: .file))
    }

    /// e.g. "3.4 MB/s".
    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond >= 1 else { return "—" }
        return Int64(bytesPerSecond).formatted(.byteCount(style: .file)) + "/s"
    }

    /// e.g. "1m 23s", "45s", "2h 5m". Returns "—" when unknown.
    static func eta(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 1 { return "<1s" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// "37%" style percentage from a 0...1 fraction.
    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Localized relative phrasing for a deadline — "in 2 hours", "3 days ago" — via the system
    /// relative formatter, so the "in"/"ago" wording is translated for free.
    static func relativeDeadline(_ date: Date, asOf now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
