import Foundation

/// Keeps the Mac from falling into *system* idle sleep while a transfer is in flight, so a long
/// download doesn't stall when the machine would otherwise nap. Uses `ProcessInfo.beginActivity`
/// — sandbox-safe and entitlement-free — and releases the assertion the instant nothing is active.
/// The display is still free to sleep; only system idle sleep is deferred.
@MainActor
final class SleepPreventer {
    private var token: (any NSObjectProtocol)?

    /// Begin or release the assertion so it matches whether any download is active. Idempotent.
    func update(active: Bool) {
        if active {
            guard token == nil else { return }
            token = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "CloakDrop is downloading files"
            )
        } else {
            guard let token else { return }
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
    }
}
