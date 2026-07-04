import Foundation
import DownloadModels

/// A playful "download tier" badge for **this month's** volume — a monthly challenge that resets, so
/// there's always a new hill to climb (and the 3 TB+ honour stays genuinely special). Pure
/// presentation: the engine only counts bytes; the names, icons, and thresholds live here.
///
/// `title`/`blurb` are English strings that double as String Catalog keys; views render them via
/// `Text(LocalizedStringKey(...))` so they localize while the type stays `Sendable`. SF Symbols only.
struct StatsBadge {
    let title: String
    let blurb: String
    let symbol: String
    /// This-month bytes at which the tier unlocks (0 = the starter tier).
    let threshold: Int64
}

enum DownloadTier {
    private static let gb: Int64 = 1_000_000_000
    private static let tb: Int64 = 1_000_000_000_000

    /// Monthly tiers, ascending — from a gentle 10 GB opener up to the 3 TB+ badge of honour, so the
    /// first rung is reachable for a casual month while the summit stays genuinely special.
    static let ladder: [StatsBadge] = [
        StatsBadge(title: "Warming Up",
                   blurb: "The month is young. So are your downloads.",
                   symbol: "tortoise.fill", threshold: 0),
        StatsBadge(title: "Byte Nibbler",
                   blurb: "Ten gigs this month. Peckish.",
                   symbol: "ant.fill", threshold: 10 * gb),
        StatsBadge(title: "Bandwidth Bandit",
                   blurb: "A hundred gigs in. The router is starting to sweat.",
                   symbol: "theatermasks.fill", threshold: 100 * gb),
        StatsBadge(title: "Data Hoarder",
                   blurb: "Half a terabyte. Marie Kondo is concerned.",
                   symbol: "archivebox.fill", threshold: 500 * gb),
        StatsBadge(title: "Warlord of the Wires",
                   blurb: "A terabyte this month. ISPs whisper your name.",
                   symbol: "crown.fill", threshold: tb),
        StatsBadge(title: "ISP’s Worst Nightmare",
                   blurb: "3 TB in one month. Somewhere, a fair-use policy weeps.",
                   symbol: "flame.fill", threshold: 3 * tb)
    ]

    /// The badge for this month's volume — the highest tier its bytes have unlocked.
    static func current(for stats: DownloadStats) -> StatsBadge {
        tier(for: stats.monthBytes)
    }

    static func tier(for monthBytes: Int64) -> StatsBadge {
        ladder.last { monthBytes >= $0.threshold } ?? ladder[0]
    }

    /// The next tier above `monthBytes`, or nil at the summit — drives the "progress to next" bar.
    static func next(after monthBytes: Int64) -> StatsBadge? {
        ladder.first { monthBytes < $0.threshold }
    }

    /// Progress in `0...1` from the current tier toward the next (1 at the summit).
    static func progress(for monthBytes: Int64) -> Double {
        let base = tier(for: monthBytes).threshold
        guard let next = next(after: monthBytes) else { return 1 }
        let span = next.threshold - base
        guard span > 0 else { return 1 }
        return min(1, max(0, Double(monthBytes - base) / Double(span)))
    }
}
