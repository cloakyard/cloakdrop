import AppKit
import Foundation

/// Watches the system pasteboard for copied links (toggleable). Polls the change count on a
/// timer — the only way to observe the pasteboard — and reports the first new valid URL.
/// Entirely local; nothing is sent anywhere.
@MainActor
final class ClipboardMonitor {
    /// Called when a new, valid http(s) URL appears on the pasteboard.
    var onURLDetected: ((URL) -> Void)?

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    func start() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let string = pasteboard.string(forType: .string),
              let url = normalizedURL(string) else { return }
        onURLDetected?(url)
    }

    private func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline) else { return nil }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil else { return nil }
        return url
    }
}
