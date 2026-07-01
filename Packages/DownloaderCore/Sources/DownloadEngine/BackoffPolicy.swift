import Foundation

/// Deterministic exponential-backoff math (no jitter), separated for testing. Jitter is
/// applied at the call site so the core schedule stays predictable in tests.
public enum BackoffPolicy {
    /// Delay before retry `attempt` (1-based): `base * 2^(attempt-1)`, capped at `maximum`.
    public static func delay(attempt: Int, base: Double, maximum: Double) -> Double {
        guard attempt >= 1 else { return 0 }
        let exponential = base * pow(2.0, Double(attempt - 1))
        return min(maximum, exponential)
    }

    /// `delay(attempt:)` plus up to ±`jitterFraction` of random spread, clamped to `[0, maximum]`.
    /// Pass a `randomUnit` in `0...1` (defaults to a fresh random value) to keep it testable.
    public static func jittered(
        attempt: Int,
        base: Double,
        maximum: Double,
        jitterFraction: Double = 0.2,
        randomUnit: Double = Double.random(in: 0...1)
    ) -> Double {
        let nominal = delay(attempt: attempt, base: base, maximum: maximum)
        let spread = nominal * jitterFraction
        let offset = (randomUnit * 2 - 1) * spread
        return min(maximum, max(0, nominal + offset))
    }
}
