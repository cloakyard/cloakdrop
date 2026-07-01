import Foundation
import DownloadModels

/// Watches for the payload-free Darwin signal the bundled extensions post after writing a capture
/// to the shared `CaptureInbox`, and runs a drain handler on the main actor. One observer for the
/// app's lifetime — it's registered once and never removed.
///
/// The Darwin callback is a C function pointer that can't capture context, so it hops to the main
/// actor and reads the handler off this singleton rather than closing over it.
@MainActor
final class CaptureInboxObserver {
    static let shared = CaptureInboxObserver()
    private var handler: (() -> Void)?
    private var isRegistered = false

    private init() {}

    /// Install the drain handler and start observing. Idempotent: later calls just replace the
    /// handler without re-registering.
    func start(_ handler: @escaping () -> Void) {
        self.handler = handler
        guard !isRegistered else { return }
        isRegistered = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, _, _, _, _ in
                Task { @MainActor in CaptureInboxObserver.shared.handler?() }
            },
            CaptureInbox.darwinNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }
}
