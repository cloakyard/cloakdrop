// The one place the engine converts clock types to Double seconds — `SpeedSampler`,
// `DownloadTask`, and `SpeedTester` all share these instead of keeping private copies,
// so a precision fix lands everywhere at once.

extension ContinuousClock.Instant {
    /// Seconds from `self` to `end`, attosecond-precise.
    func seconds(to end: ContinuousClock.Instant) -> Double {
        duration(to: end).timeInterval
    }
}

extension Duration {
    /// The duration as fractional seconds. (Named to avoid the `Duration.seconds(_:)` factory.)
    var timeInterval: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// A sliding-window transfer-rate estimator.
///
/// Records `(timestamp, byteCount)` samples and reports bytes/sec over a fixed trailing
/// window, which smooths the bursty arrival of network chunks into a steady speed readout.
struct SpeedSampler {
    private var samples: [(at: ContinuousClock.Instant, bytes: Int64)] = []
    /// Index of the first live sample. Advancing an index is O(1), unlike repeatedly removing the
    /// leading expired prefix from an `Array`, which shifts every retained sample on the hot path.
    private var head = 0
    /// Running sum of `samples[*].bytes`, maintained incrementally so `rate()` never re-`reduce`s the
    /// window. This runs on the per-chunk hot path, so both add and prune must stay O(expired), not O(n).
    private var runningSum: Int64 = 0
    private let window: Double
    /// Reclaim dead prefix storage occasionally. Waiting for both a meaningful dead prefix and for it
    /// to occupy at least half the buffer keeps compaction amortized O(1) while bounding retained memory.
    private static let compactionThreshold = 1_024

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
        guard head < samples.count else { return 0 }
        let first = samples[head]
        let elapsed = first.at.seconds(to: now)
        guard elapsed > 0.05 else { return 0 }
        return Double(runningSum) / elapsed
    }

    private mutating func prune(now: ContinuousClock.Instant) {
        // Samples are appended in time order, so expired entries are always a leading prefix. Move a
        // logical head across them without shifting the live tail; compact only occasionally below.
        while head < samples.count, samples[head].at.seconds(to: now) > window {
            runningSum -= samples[head].bytes
            head += 1
        }

        if head == samples.count {
            // Everything expired. Reset the logical buffer while retaining its allocation for reuse.
            samples.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= Self.compactionThreshold, head >= samples.count / 2 {
            // Copy the live suffix once after many O(1) prunes, rather than shifting it for every sample.
            samples = Array(samples[head...])
            head = 0
        }
    }
}
