import Foundation

/// Pure token-bucket arithmetic, separated from time and concurrency so it can be tested
/// deterministically.
enum TokenBucketMath {
    /// Plan a consumption of `requested` tokens.
    ///
    /// - Returns: `wait` — seconds to sleep before the request is satisfiable — and
    ///   `tokensAfter` — the bucket balance once the request has been granted.
    static func plan(
        tokens: Double,
        ratePerSecond: Double,
        requested: Double
    ) -> (wait: Double, tokensAfter: Double) {
        guard ratePerSecond > 0 else { return (0, tokens) }
        if tokens >= requested {
            return (0, tokens - requested)
        }
        let deficit = requested - tokens
        let wait = deficit / ratePerSecond
        // After waiting, exactly `deficit` tokens refill and are immediately consumed.
        return (wait, 0)
    }

    /// Refill the bucket for `elapsed` seconds, capped at `capacity`.
    static func refill(tokens: Double, ratePerSecond: Double, elapsed: Double, capacity: Double) -> Double {
        min(capacity, tokens + max(0, elapsed) * ratePerSecond)
    }
}

/// A shared, actor-isolated token-bucket rate limiter.
///
/// Segment readers call `awaitAllowance(byteCount:)` before writing each chunk; when a
/// global or per-download speed limit is set, the call suspends just long enough to keep
/// the aggregate throughput at or below the limit. With no limit it is a cheap no-op.
public actor BandwidthLimiter {
    private var ratePerSecond: Double?
    private var tokens: Double = 0
    private var lastRefill: ContinuousClock.Instant
    private let clock = ContinuousClock()
    /// Seconds of burst the bucket may accumulate, smoothing bursty readers.
    private static let burstSeconds: Double = 0.5

    public init(bytesPerSecond: Int64?) {
        let rate = bytesPerSecond.flatMap { $0 > 0 ? Double($0) : nil }
        self.ratePerSecond = rate
        self.lastRefill = clock.now
        self.tokens = rate.map { $0 * Self.burstSeconds } ?? 0
    }

    /// Update the limit at runtime. `nil` or `<= 0` means unlimited.
    public func setRate(bytesPerSecond: Int64?) {
        ratePerSecond = bytesPerSecond.flatMap { $0 > 0 ? Double($0) : nil }
        if let rate = ratePerSecond {
            tokens = min(tokens, rate * Self.burstSeconds)
        }
        // Reset the refill clock so a long unlimited (or idle) stretch can't be read as a
        // huge `elapsed` and inject a spurious burst the moment a limit is applied.
        lastRefill = clock.now
    }

    /// Suspend until `byteCount` bytes are permitted under the current rate.
    public func awaitAllowance(byteCount: Int) async {
        guard let rate = ratePerSecond, rate > 0 else { return }
        let capacity = rate * Self.burstSeconds

        let now = clock.now
        let elapsed = Self.seconds(from: lastRefill, to: now, clock: clock)
        lastRefill = now
        tokens = TokenBucketMath.refill(tokens: tokens, ratePerSecond: rate, elapsed: elapsed, capacity: capacity)

        let (wait, tokensAfter) = TokenBucketMath.plan(
            tokens: tokens,
            ratePerSecond: rate,
            requested: Double(byteCount)
        )
        tokens = tokensAfter
        if wait > 0 {
            // The `deficit` tokens this request consumes accrue *during* the sleep. Advance the
            // refill clock past the sleep so the next call doesn't re-credit that same window —
            // double-counting it is what let throughput overshoot the limit (up to ~2×) for
            // chunks comparable to the burst capacity.
            lastRefill = now.advanced(by: .seconds(wait))
            try? await clock.sleep(for: .seconds(wait))
        }
    }

    private static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant, clock: ContinuousClock) -> Double {
        let d = start.duration(to: end)
        let (secs, attos) = d.components
        return Double(secs) + Double(attos) / 1e18
    }
}
