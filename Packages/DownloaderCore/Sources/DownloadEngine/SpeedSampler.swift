import Foundation

/// A sliding-window transfer-rate estimator.
///
/// Records `(timestamp, byteCount)` samples and reports bytes/sec over a fixed trailing
/// window, which smooths the bursty arrival of network chunks into a steady speed readout.
struct SpeedSampler {
    private var samples: [(at: ContinuousClock.Instant, bytes: Int64)] = []
    /// Running sum of `samples[*].bytes`, maintained incrementally so `rate()` never re-`reduce`s the
    /// window. This runs on the per-chunk hot path, so both add and prune must stay O(expired), not O(n).
    private var runningSum: Int64 = 0
    private let window: Double

    init(windowSeconds: Double = 1.5) {
        self.window = windowSeconds
    }

    mutating func add(bytes: Int64, at instant: ContinuousClock.Instant) {
        samples.append((instant, bytes))
        runningSum += bytes
        prune(now: instant)
    }

    /// Estimated bytes/sec at `now`, or 0 when there is too little data.
    mutating func rate(now: ContinuousClock.Instant) -> Double {
        prune(now: now)
        guard let first = samples.first else { return 0 }
        let elapsed = Self.seconds(from: first.at, to: now)
        guard elapsed > 0.05 else { return 0 }
        return Double(runningSum) / elapsed
    }

    private mutating func prune(now: ContinuousClock.Instant) {
        // Samples are appended in time order, so the expired ones are always a leading prefix. Drop
        // that prefix in one shot (subtracting from the running sum) instead of scanning/compacting
        // the whole array with `removeAll` on every call.
        var expired = 0
        while expired < samples.count, Self.seconds(from: samples[expired].at, to: now) > window {
            runningSum -= samples[expired].bytes
            expired += 1
        }
        if expired > 0 { samples.removeFirst(expired) }
    }

    private static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let (secs, attos) = start.duration(to: end).components
        return Double(secs) + Double(attos) / 1e18
    }
}
