import Synchronization

/// Pure rate-scheduling arithmetic, separated from time and concurrency so it can be tested
/// deterministically. Models a token bucket as a **virtual clock** (a "theoretical arrival time",
/// TAT): each request reserves `cost = bytes / rate` seconds of emission time by advancing the TAT,
/// and may run up to `burst` seconds ahead of it. Expressing the schedule as *absolute* wake instants
/// — rather than a per-call `now + wait` sleep — is what makes it correct under concurrency: many
/// callers advancing the same TAT get strictly increasing deadlines spaced by their cost, so they
/// serialize even though their sleeps overlap.
enum RateSchedule {
    /// Reserve one request against the bucket.
    ///
    /// - Parameters:
    ///   - tat: the current theoretical arrival time (seconds, same basis as `now`).
    ///   - now: the current real time (seconds).
    ///   - cost: this request's emission time, `bytes / ratePerSecond` (seconds).
    ///   - burst: how far ahead of the virtual clock a request may run (seconds).
    /// - Returns: `tat` — the advanced virtual clock the next request reserves against — and
    ///   `wakeAt` — the absolute instant this request may complete (≤ `now` means "no wait").
    static func reserve(tat: Double, now: Double, cost: Double, burst: Double) -> (tat: Double, wakeAt: Double) {
        // If the bucket went idle (TAT fell behind real time) it has fully refilled: restart from now.
        let base = max(tat, now)
        let newTAT = base + cost
        // Wait until this request's emission finishes, minus the burst it's allowed to run ahead.
        return (newTAT, newTAT - burst)
    }
}

/// A shared, actor-isolated rate limiter.
///
/// Segment readers call `awaitAllowance(byteCount:)` before writing each chunk; when a global or
/// per-download speed limit is set, the call suspends just long enough to keep the aggregate
/// throughput at or below the limit. With no limit it is a cheap no-op.
///
/// **Correct under concurrency.** One limiter instance is deliberately shared by many workers — the
/// engine gives every segment of a download the *same* per-download limiter and every download the
/// *same* global limiter, so a limit caps the shared aggregate rather than each worker independently.
/// The reservation (advancing `tat`) happens in the actor's synchronous section before any `await`,
/// so reentrancy during the sleep cannot let concurrent callers double-spend the same time window.
public actor BandwidthLimiter {
    private var ratePerSecond: Double?
    /// The theoretical arrival time — the virtual instant the bucket is "filled up to". Requests
    /// reserve emission time by advancing it; `nil` until the first reservation (or after a rate change).
    private var tat: ContinuousClock.Instant?
    private let clock = ContinuousClock()
    /// Seconds of burst a request may run ahead of the virtual clock, smoothing bursty readers.
    private static let burstSeconds: Double = 0.5
    /// A lock-free mirror of "is a limit currently set", readable **without** hopping onto the actor.
    /// The per-chunk hot path checks this first so an unlimited limiter (the default) costs nothing —
    /// no suspension, no actor hop. A stale read is harmless: at worst one chunk takes the slow path
    /// right as a limit toggles.
    private let limited = Atomic<Bool>(false)

    public init(bytesPerSecond: Int64?) {
        let rate = bytesPerSecond.flatMap { $0 > 0 ? Double($0) : nil }
        self.ratePerSecond = rate
        self.limited.store(rate != nil, ordering: .relaxed)
    }

    /// Whether a rate limit is in effect, cheap to read from any isolation. Callers on the hot path
    /// skip `awaitAllowance` entirely when this is `false`.
    public nonisolated var isLimited: Bool { limited.load(ordering: .relaxed) }

    /// Update the limit at runtime. `nil` or `<= 0` means unlimited. Resets the virtual clock so the
    /// new rate takes effect immediately without inheriting a stale backlog.
    ///
    /// A no-op when the rate is unchanged: the bandwidth ticker re-applies the effective limit every
    /// minute, and resetting `tat` each time would discard the reservation backlog and hand out a fresh
    /// burst — letting sustained throughput drift above the cap. Only a genuine change resets the clock.
    public func setRate(bytesPerSecond: Int64?) {
        let newRate = bytesPerSecond.flatMap { $0 > 0 ? Double($0) : nil }
        guard newRate != ratePerSecond else { return }
        ratePerSecond = newRate
        tat = nil
        limited.store(newRate != nil, ordering: .relaxed)
    }

    /// Suspend until `byteCount` bytes are permitted under the current rate.
    public func awaitAllowance(byteCount: Int) async {
        guard let rate = ratePerSecond, rate > 0, byteCount > 0 else { return }

        let now = clock.now
        // Advance the shared virtual clock and compute this request's absolute wake instant. This
        // whole block is synchronous (no `await`), so it is atomic against other callers on the actor.
        let base = { () -> ContinuousClock.Instant in
            guard let tat, tat > now else { return now }   // fresh / idle bucket → start from now
            return tat
        }()
        let cost = Duration.seconds(Double(byteCount) / rate)
        let newTAT = base.advanced(by: cost)
        tat = newTAT
        let wakeAt = newTAT.advanced(by: .seconds(-Self.burstSeconds))

        if wakeAt > now {
            try? await clock.sleep(until: wakeAt, tolerance: nil)
        }
    }
}
