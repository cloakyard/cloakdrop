import Foundation
import DownloadModels

// CloakDrop native-messaging host — the bridge for the Chrome / Edge / Firefox extension (Phase 3c).
//
// The browsers launch this small helper (bundled inside CloakDrop.app) when their extension calls
// `runtime.sendNativeMessage`. It speaks the browsers' stdio wire format — a 4-byte little-endian
// length prefix followed by JSON — reading one capture, validating it (the same `CapturedDownload`
// bounds every intake path uses), dropping it into the shared App Group inbox for the running app,
// and posting the Darwin wake signal. It then replies with a tiny ack.
//
// Why a separate helper: the URL scheme can't carry a large `Cookie` header, so gated downloads need
// a fatter channel. Native messaging is that channel; the inbox keeps the data inside the container
// both processes are entitled to (no browser↔app network path, nothing logged).
//
// Privacy & sandbox: the host makes no network connections and talks only to the extension (stdio)
// and the app (shared container). When the App Group isn't available — an unsigned/dev build without
// the entitlement — it replies `{ok:false, error:"container-unavailable"}` so the extension falls
// back to the `cloakdrop://` deep link. See CaptureInbox for the shared-inbox hand-off.

/// Decode one message, relay a valid capture to the inbox, and produce the reply dictionary.
func handle(_ message: Data) -> [String: Any] {
    guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any] else {
        return ["ok": false, "error": "invalid-json"]
    }
    do {
        let capture = try CapturedDownload.parse(extensionMessage: object, source: .browserExtension)
        return relay(capture)
    } catch {
        return ["ok": false, "error": String(describing: error)]
    }
}

/// Hand a validated capture to the app through the shared inbox.
///
/// Gated on `APP_GROUP_INBOX` (defined only in the Release config that also carries the App Group
/// entitlement). It's not enough that `CaptureInbox.write` *succeeds*: this host runs unsandboxed, so
/// without the entitlement it still gets a private Group Containers path and would write to a folder
/// the sandboxed app can't read — silently losing the capture. So in Debug/dev builds we report the
/// inbox unavailable, and the extension falls back to the cloakdrop:// deep link (as the sandboxed
/// Safari extension already does). The real inbox path is exercised in a team-signed Release build.
func relay(_ capture: CapturedDownload) -> [String: Any] {
    #if APP_GROUP_INBOX
    do {
        try CaptureInbox.write(capture)
        CaptureInbox.postNotification()
        return ["ok": true]
    } catch {
        return ["ok": false, "error": "container-unavailable"]
    }
    #else
    return ["ok": false, "error": "container-unavailable"]
    #endif
}

let input = FileHandle.standardInput
let output = FileHandle.standardOutput

// `sendNativeMessage` normally delivers a single message per launch, but loop so a `connectNative`
// port sending several is handled too. Exit on EOF (browser closed the pipe) or a framing violation.
while true {
    let message: Data?
    do {
        message = try NativeMessaging.readMessage(from: input)
    } catch {
        break // oversized/framing error — drop the session; the browser relaunches us next time
    }
    guard let message else { break } // clean EOF or truncated stream

    let reply = handle(message)
    let payload = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data(#"{"ok":false}"#.utf8)
    guard let framed = try? NativeMessaging.frame(payload) else { continue }
    try? output.write(contentsOf: framed)
}
