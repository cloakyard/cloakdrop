import Foundation
import SafariServices
import os.log
import DownloadModels

/// Native half of the CloakDrop Safari Web Extension. Safari invokes this (out of process, inside
/// the app bundle) with the message `background.js` sends when the user picks "Download with
/// CloakDrop". It validates the capture, drops it in the shared App Group inbox, and posts the
/// Darwin wake signal — the running app drains the inbox and shows its confirm banner.
///
/// The extension never touches the network and never talks to the app directly: its only outputs
/// are a file in the container both are entitled to and a payload-free notification.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let log = Logger(subsystem: "com.cloakyard.cloakdrop.SafariExtension", category: "capture")

    func beginRequest(with context: NSExtensionContext) {
        let message = (context.inputItems.first as? NSExtensionItem)?
            .userInfo?[SFExtensionMessageKey] as? [String: Any]

        let reply = NSExtensionItem()
        do {
            guard let message else { throw CapturedDownload.CaptureError.missingURL }
            let capture = try CapturedDownload.parse(extensionMessage: message, source: .safariExtension)
            try CaptureInbox.write(capture)
            CaptureInbox.postNotification()
            reply.userInfo = [SFExtensionMessageKey: ["ok": true]]
        } catch {
            log.error("capture rejected: \(String(describing: error), privacy: .public)")
            reply.userInfo = [SFExtensionMessageKey: ["ok": false, "error": "\(error)"]]
        }
        context.completeRequest(returningItems: [reply], completionHandler: nil)
    }
}
