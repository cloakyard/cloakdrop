import Foundation

/// Limits expensive ambient updates while delivering the last tick after a burst of progress.
@MainActor
final class AmbientRefreshThrottle {
    private let interval: Duration
    private let clock = ContinuousClock()
    private var lastRefresh: ContinuousClock.Instant?
    private var pending: Task<Void, Never>?

    init(interval: Duration = .milliseconds(333)) {
        self.interval = interval
    }

    func schedule(_ refresh: @escaping @MainActor () -> Void) {
        guard let lastRefresh, clock.now < lastRefresh.advanced(by: interval) else {
            refresh()
            return
        }
        guard pending == nil else { return }
        let deadline = lastRefresh.advanced(by: interval)
        pending = Task {
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch { return }
            refresh()
        }
    }

    /// Status events refresh immediately, superseding any pending progress refresh.
    func didRefresh() {
        pending?.cancel()
        pending = nil
        lastRefresh = clock.now
    }

    deinit { pending?.cancel() }
}
