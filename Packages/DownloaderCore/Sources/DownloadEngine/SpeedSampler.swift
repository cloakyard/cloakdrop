import Foundation

/// A sliding-window transfer-rate estimator.
///
/// Records `(timestamp, byteCount)` samples and reports bytes/sec over a fixed trailing
/// window, which smooths the bursty arrival of network chunks into a steady speed readout.
struct SpeedSampler {
    private var samples: [(at: ContinuousClock.Instant, bytes: Int64)] = []
    private let window: Double

    init(windowSeconds: Double = 1.5) {
        self.window = windowSeconds
    }

    mutating func add(bytes: Int64, at instant: ContinuousClock.Instant) {
        samples.append((instant, bytes))
        prune(now: instant)
    }

    /// Estimated bytes/sec at `now`, or 0 when there is too little data.
    mutating func rate(now: ContinuousClock.Instant) -> Double {
        prune(now: now)
        guard let first = samples.first else { return 0 }
        let elapsed = Self.seconds(from: first.at, to: now)
        guard elapsed > 0.05 else { return 0 }
        let total = samples.reduce(Int64(0)) { $0 + $1.bytes }
        return Double(total) / elapsed
    }

    private mutating func prune(now: ContinuousClock.Instant) {
        let cutoff = window
        samples.removeAll { Self.seconds(from: $0.at, to: now) > cutoff }
    }

    private static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let (secs, attos) = start.duration(to: end).components
        return Double(secs) + Double(attos) / 1e18
    }
}
