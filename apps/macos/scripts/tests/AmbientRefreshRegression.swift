import Foundation

/// swiftc App/Ambient/AmbientRefreshThrottle.swift scripts/tests/AmbientRefreshRegression.swift -o /tmp/ambient-regression
@main
struct AmbientRefreshRegression {
    @MainActor
    static func main() async throws {
        let throttle = AmbientRefreshThrottle(interval: .milliseconds(30))
        let state = State()
        let refresh: @MainActor () -> Void = {
            throttle.didRefresh()
            state.drawn.append(state.value)
        }
        throttle.schedule(refresh)
        precondition(state.drawn == [0])
        state.value = 1
        throttle.schedule(refresh)
        state.value = 2
        throttle.schedule(refresh)
        precondition(state.drawn == [0], "A progress burst should be coalesced")
        try await Task.sleep(for: .milliseconds(100))
        precondition(state.drawn == [0, 2], "The final value must render even when no further events arrive")

        state.value = 3
        refresh()
        state.value = 4
        throttle.schedule(refresh)
        state.value = 5
        refresh()
        try await Task.sleep(for: .milliseconds(100))
        precondition(state.drawn == [0, 2, 3, 5], "An immediate status refresh supersedes the pending tick")
        print("Ambient refresh regression checks passed")
    }

    @MainActor
    private final class State {
        var value = 0
        var drawn: [Int] = []
    }
}
