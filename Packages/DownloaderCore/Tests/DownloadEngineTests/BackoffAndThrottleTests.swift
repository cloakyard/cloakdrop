import Foundation
import Testing
@testable import DownloadEngine

@Suite("Backoff policy")
struct BackoffPolicyTests {
    @Test("Exponential growth, capped at the maximum")
    func exponential() {
        #expect(BackoffPolicy.delay(attempt: 1, base: 1, maximum: 30) == 1)
        #expect(BackoffPolicy.delay(attempt: 2, base: 1, maximum: 30) == 2)
        #expect(BackoffPolicy.delay(attempt: 3, base: 1, maximum: 30) == 4)
        #expect(BackoffPolicy.delay(attempt: 4, base: 1, maximum: 30) == 8)
        #expect(BackoffPolicy.delay(attempt: 10, base: 1, maximum: 30) == 30) // capped
    }

    @Test("Jitter stays within bounds and never negative")
    func jitterBounds() {
        for unit in [0.0, 0.5, 1.0] {
            let value = BackoffPolicy.jittered(attempt: 3, base: 1, maximum: 30, jitterFraction: 0.2, randomUnit: unit)
            #expect(value >= 0)
            #expect(value <= 30)
            // attempt 3 nominal = 4, ±20% → [3.2, 4.8]
            #expect(value >= 3.2 - 0.0001)
            #expect(value <= 4.8 + 0.0001)
        }
    }
}

@Suite("Token-bucket math")
struct TokenBucketMathTests {
    @Test("Spends available tokens with no wait")
    func noWaitWhenFunded() {
        let (wait, after) = TokenBucketMath.plan(tokens: 1000, ratePerSecond: 1000, requested: 400)
        #expect(wait == 0)
        #expect(after == 600)
    }

    @Test("Waits exactly the deficit divided by rate")
    func waitsForDeficit() {
        // Need 1000, have 200, rate 100/s → deficit 800 → 8 s.
        let (wait, after) = TokenBucketMath.plan(tokens: 200, ratePerSecond: 100, requested: 1000)
        #expect(wait == 8.0)
        #expect(after == 0)
    }

    @Test("Unlimited rate never waits")
    func unlimited() {
        let (wait, after) = TokenBucketMath.plan(tokens: 0, ratePerSecond: 0, requested: 5000)
        #expect(wait == 0)
        #expect(after == 0)
    }

    @Test("Refill is clamped to capacity")
    func refillClamp() {
        let refilled = TokenBucketMath.refill(tokens: 500, ratePerSecond: 1000, elapsed: 10, capacity: 1000)
        #expect(refilled == 1000)
    }
}

@Suite("Bandwidth limiter (actor)")
struct BandwidthLimiterTests {
    private func seconds(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Double {
        let (s, a) = start.duration(to: end).components
        return Double(s) + Double(a) / 1e18
    }

    /// The real-time guard against the refill double-count: with chunks larger than the burst
    /// capacity (here 600 KB chunks vs a 500 KB burst at 1 MB/s), the limiter must hold actual
    /// throughput at/below the rate. The pre-fix bug re-credited the sleep window and finished
    /// ~2× too fast, so the lower time bound discriminates it.
    @Test("Holds throughput at or below the limit for chunks larger than the burst")
    func holdsRateForLargeChunks() async {
        let rate: Int64 = 1_000_000           // 1 MB/s → burst capacity 500 KB
        let chunk = 600_000                    // > capacity → every chunk must wait
        let limiter = BandwidthLimiter(bytesPerSecond: rate)

        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<3 { await limiter.awaitAllowance(byteCount: chunk) }   // 1.8 MB total
        let elapsed = seconds(start, clock.now)

        // 1.8 MB at 1 MB/s, minus the one-time 500 KB burst ≈ 1.3 s. The double-count bug
        // finished ~0.7 s. Lower bound catches overshoot; generous upper bound avoids flakiness.
        #expect(elapsed >= 1.1)
        #expect(elapsed < 3.0)
    }
}
