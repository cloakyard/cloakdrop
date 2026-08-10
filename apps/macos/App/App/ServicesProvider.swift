import AppKit

/// Backs the "Send to CloakDrop" macOS Services item (declared as `NSServices` in Info.plist). When
/// the user selects a link in any app and picks the service, macOS hands us the pasteboard here; we
/// pull the web URL(s) out and route them through the app's confirm banner.
///
/// Registered as `NSApp.servicesProvider` at launch. `NSApplication` doesn't retain its services
/// provider, so `AppDelegate` keeps a strong reference for us.
final class ServicesProvider: NSObject {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    /// The `NSMessage` named in Info.plist. AppKit delivers service requests on the main thread —
    /// hence `@MainActor` — with the selection's pasteboard; we accept explicit URLs first, then fall
    /// back to parsing a plain-text selection.
    @MainActor
    @objc
    func sendToCloakDrop(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        var urls: [URL] = []
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            urls = objects.filter { $0.scheme == "http" || $0.scheme == "https" }
        }
        if urls.isEmpty, let text = pasteboard.string(forType: .string), let url = AppModel.normalizedURL(text) {
            urls = [url]
        }
        guard !urls.isEmpty else { return }
        model.captureSystemURLs(urls)
    }
}
