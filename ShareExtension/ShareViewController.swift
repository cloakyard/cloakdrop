import AppKit
import UniformTypeIdentifiers
import DownloadModels

/// The native "share to CloakDrop" path (Phase 3d). The macOS share sheet hands this extension a
/// single web URL (from Safari or any app); it validates the URL with the shared `CapturedDownload`
/// bounds and drops it in the App Group inbox for the running app to confirm — the same inbox the
/// Safari and browser extensions use.
///
/// The activation rule (`NSExtensionActivationSupportsWebURLWithMaxCount = 1`) means we only ever get
/// one URL, so there's no batching to coordinate. If the shared container is unavailable (an
/// unsigned/dev build without the App Group), we fall back to the `cloakdrop://` deep link.
///
/// Privacy: the extension has no network access; the URL crosses to the app through the shared
/// container (or the deep link), never the network.
final class ShareViewController: NSViewController {
    override func loadView() {
        // A small non-empty view so macOS doesn't flash a blank sheet before we complete.
        let label = NSTextField(labelWithString: "Sending to CloakDrop…")
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let provider = firstURLProvider() else { return finish() }
        provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, _ in
            let url = item as? URL
            Task { @MainActor in
                self?.handOff(url)
                self?.finish()
            }
        }
    }

    /// The first shared attachment that carries a URL.
    private func firstURLProvider() -> NSItemProvider? {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        for item in items {
            for provider in item.attachments ?? [] where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                return provider
            }
        }
        return nil
    }

    /// Validate and relay the shared URL: inbox first, deep link as a fallback.
    private func handOff(_ url: URL?) {
        guard let url, url.scheme == "http" || url.scheme == "https",
              let capture = try? CapturedDownload(url: url, source: .shareExtension).validated() else { return }
        do {
            try CaptureInbox.write(capture)
            CaptureInbox.postNotification()
        } catch {
            // No shared container (dev build) → hand off via the deep link instead.
            if let link = capture.cloakdropURL() {
                NSWorkspace.shared.open(link)
            }
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
