import Synchronization

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
    private var rateRevision: UInt = 0
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
        rateRevision &+= 1
        limited.store(newRate != nil, ordering: .relaxed)
    }

    /// Suspend until `byteCount` bytes are permitted under the current rate.
    public func awaitAllowance(byteCount: Int) async {
        guard byteCount > 0 else { return }
        while let rate = ratePerSecond, !Task.isCancelled {
            let revision = rateRevision
            let now = clock.now
            // Reserve atomically before suspension so concurrent workers share the same budget.
            let base = max(tat ?? now, now)
            let newTAT = base.advanced(by: .seconds(Double(byteCount) / rate))
            tat = newTAT
            let wakeAt = newTAT.advanced(by: .seconds(-Self.burstSeconds))

            // A low rate can reserve minutes for one chunk. Recheck settings while waiting so raising
            // or disabling the limit takes effect promptly for existing workers, not just new ones.
            while clock.now < wakeAt, revision == rateRevision, !Task.isCancelled {
                try? await clock.sleep(until: min(wakeAt, clock.now + .milliseconds(250)), tolerance: nil)
            }
            if revision == rateRevision { return }
        }
    }
}
