import Foundation
import Network

/// Reachability source for the engine. A protocol so production uses `NWPathMonitor` while
/// tests inject a deterministic stream.
public protocol NetworkPathMonitoring: Sendable {
    /// Yields the current reachability, then one value per change.
    func reachabilityUpdates() -> AsyncStream<Bool>
}

/// Always reports the network as reachable. Used by tests and SwiftUI previews where the
/// real path monitor would otherwise gate mock transfers.
public struct AlwaysReachableMonitor: NetworkPathMonitoring {
    public init() {}
    public func reachabilityUpdates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            continuation.yield(true)
            continuation.finish()
        }
    }
}

/// Observes network reachability via `NWPathMonitor` and exposes it as an async stream of
/// "is the network usable" booleans. The engine uses transitions from `false → true` to
/// auto-resume downloads that were interrupted by connectivity loss.
public final class NetworkMonitor: NetworkPathMonitoring, Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.cloakyard.cloakdrop.network-monitor")

    public init() {}

    /// A stream that yields the current reachability immediately, then on every change.
    /// Cancelling the consuming task stops monitoring.
    public func reachabilityUpdates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied)
            }
            continuation.onTermination = { [monitor] _ in
                monitor.cancel()
            }
            monitor.start(queue: queue)
        }
    }
}
