import Foundation
import Testing
@testable import DownloadEngine

@Suite("Speed sampler")
struct SpeedSamplerTests {
    @Test("Rate includes only samples in the trailing window")
    func trailingWindow() {
        let start = ContinuousClock().now
        var sampler = SpeedSampler(windowSeconds: 1.0)
        sampler.add(bytes: 100, at: start)
        sampler.add(bytes: 200, at: start.advanced(by: .milliseconds(500)))

        // At 1.25 s the first sample has expired. The remaining 200 bytes span 0.75 s.
        let rate = sampler.rate(now: start.advanced(by: .milliseconds(1_250)))
        #expect(abs(rate - (200.0 / 0.75)) < 0.001)
    }

    @Test("Many rolling samples preserve the rate through repeated compaction")
    func manyRollingSamples() {
        let start = ContinuousClock().now
        var sampler = SpeedSampler(windowSeconds: 1.0)
        var instant = start

        // Far more samples than the compaction threshold, with a steady 1 KiB/ms stream. The live
        // window remains 1,000 samples even as almost 100,000 older samples expire.
        for _ in 0..<100_000 {
            sampler.add(bytes: 1_024, at: instant)
            instant = instant.advanced(by: .milliseconds(1))
        }

        let rate = sampler.rate(now: instant)
        #expect(abs(rate - 1_024_000) < 0.001)

        // Expiring the entire buffer and reusing it must not retain bytes in the running sum.
        let resumedAt = instant.advanced(by: .seconds(3))
        #expect(sampler.rate(now: resumedAt) == 0)
        sampler.add(bytes: 500, at: resumedAt)
        #expect(abs(sampler.rate(now: resumedAt.advanced(by: .milliseconds(100))) - 5_000) < 0.001)
    }
}

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

@Suite("Rate schedule (virtual-clock reservation)")
struct RateScheduleTests {
    private let burst = 0.5   // seconds

    @Test("An idle bucket serves a within-burst request with no wait")
    func idleWithinBurstNoWait() {
        // Bucket idle (tat behind now); 100 KB at 1 MB/s = 0.1 s cost < 0.5 s burst → wakeAt in the past.
        let (tat, wakeAt) = RateSchedule.reserve(tat: 0, now: 10, cost: 0.1, burst: burst)
        #expect(tat == 10.1)          // reservation starts from `now`, not the stale tat
        #expect(wakeAt <= 10)         // no wait
    }

    @Test("Successive reservations serialize, spaced by their cost")
    func successiveReservationsSpace() {
        // Three back-to-back 600 KB chunks (0.6 s each) at the same instant. The virtual clock, not
        // `now`, spaces them — so their absolute wake instants step by 0.6 s regardless of overlap.
        let now = 10.0
        let (t1, w1) = RateSchedule.reserve(tat: 0, now: now, cost: 0.6, burst: burst)
        let (t2, w2) = RateSchedule.reserve(tat: t1, now: now, cost: 0.6, burst: burst)
        let (_, w3) = RateSchedule.reserve(tat: t2, now: now, cost: 0.6, burst: burst)
        #expect(abs(w1 - (now + 0.1)) < 1e-9)   // 0.6 − 0.5 burst
        #expect(abs(w2 - (now + 0.7)) < 1e-9)
        #expect(abs(w3 - (now + 1.3)) < 1e-9)   // steady 0.6 s spacing → the aggregate rate
    }

    @Test("A bucket that fell behind resets to now rather than accumulating backlog")
    func idleResets() {
        // tat is far in the past relative to now → base is `now`, no burst of catch-up traffic.
        let (tat, wakeAt) = RateSchedule.reserve(tat: 1, now: 100, cost: 0.6, burst: burst)
        #expect(tat == 100.6)
        #expect(abs(wakeAt - 100.1) < 1e-9)
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

    /// The invariant both real limits rely on: **one** limiter instance shared by many concurrent
    /// consumers caps their *aggregate* throughput, not each consumer independently. This is exactly
    /// how the engine enforces a per-download limit (one limiter shared across a download's segment
    /// workers) and the global limit (one limiter shared across every download). Four workers hammering
    /// the same 1 MB/s bucket must still finish no faster than the aggregate rate allows — if each got
    /// its own effective allowance they'd finish ~4× too fast.
    @Test("A shared limiter caps aggregate throughput across concurrent consumers")
    func sharedLimiterCapsAggregate() async {
        let rate: Int64 = 1_000_000           // 1 MB/s → burst capacity 500 KB
        let workers = 4
        let chunksEach = 6
        let chunk = 100_000                    // 4 × 6 × 100 KB = 2.4 MB total
        let limiter = BandwidthLimiter(bytesPerSecond: rate)

        let clock = ContinuousClock()
        let start = clock.now
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workers {
                group.addTask {
                    for _ in 0..<chunksEach { await limiter.awaitAllowance(byteCount: chunk) }
                }
            }
        }
        let elapsed = seconds(start, clock.now)

        // 2.4 MB at 1 MB/s ≈ 2.4 s, minus the one-time 500 KB burst ≈ 1.9 s. A per-consumer bucket
        // would let all four run in ~0.5 s. Lower bound proves the cap is aggregate; upper bound is
        // generous against scheduler jitter.
        #expect(elapsed >= 1.5)
        #expect(elapsed < 4.5)
    }
}
