import Foundation
import AppKit
import DownloadModels

/// Installs (and removes) the native-messaging host manifests that let the Chrome / Edge / Brave /
/// Firefox extension reach CloakDrop (Phase 3c).
///
/// Each browser looks for a small JSON manifest in its own `NativeMessagingHosts` folder; the
/// manifest points at the bundled `CloakDropNativeHost` executable and whitelists our extension by
/// id. When the extension calls `sendNativeMessage`, the browser launches that helper, which drops
/// the capture into CloakDrop's shared inbox (see `CaptureInbox`).
///
/// **Sandbox.** Those folders live in the *real* `~/Library/Application Support`, outside the app
/// container, so we can't write them silently. The user grants access to the browser's support
/// folder through an open panel — the sanctioned sandbox path — and we persist a security-scoped
/// bookmark so a later reinstall or uninstall doesn't prompt again.
@MainActor
@Observable
final class NativeMessagingInstaller {
    /// Must match the extension's `HOST_NAME` and the manifest file name.
    static let hostName = "com.cloakyard.cloakdrop"
    /// Pinned by the committed public key in `manifest.chrome.json`; Chrome, Edge, and Brave (all
    /// Chromium) derive the same id from that key.
    static let chromeExtensionID = "mhkmioglakbnadmifmcbjjmoolinoopg"
    static let firefoxAddonID = "cloakdrop@cloakyard.com"

    /// The browsers we can install into. Adding one is a single case plus its support subpath.
    enum Browser: String, CaseIterable, Identifiable {
        case chrome, edge, brave, firefox
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .chrome: return "Google Chrome"
            case .edge: return "Microsoft Edge"
            case .brave: return "Brave"
            case .firefox: return "Firefox"
            }
        }

        /// Path under the real `~/Library/Application Support` whose `NativeMessagingHosts` subfolder
        /// the browser scans.
        var supportSubpath: String {
            switch self {
            case .chrome: return "Google/Chrome"
            case .edge: return "Microsoft Edge"
            case .brave: return "BraveSoftware/Brave-Browser"
            case .firefox: return "Mozilla"
            }
        }

        /// Firefox uses `allowed_extensions` (add-on id); the Chromium browsers use `allowed_origins`.
        var isGecko: Bool { self == .firefox }
    }

    enum InstallError: LocalizedError {
        case hostExecutableMissing
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .hostExecutableMissing:
                return "CloakDrop couldn’t find its native-messaging helper. Reinstall the app and try again."
            case .writeFailed(let detail):
                return "Couldn’t write the browser integration file: \(detail)"
            }
        }
    }

    /// Browsers we've installed into, tracked in UserDefaults — the manifests live outside the
    /// container, so we can't reliably stat them; our own record is the source of truth for the UI.
    private(set) var installed: Set<String>

    private static let installedKey = "installedNativeMessagingHosts"
    private static let bookmarkKeyPrefix = "nativeMessagingBookmark."

    init() {
        installed = Set(UserDefaults.standard.stringArray(forKey: Self.installedKey) ?? [])
    }

    func isInstalled(_ browser: Browser) -> Bool { installed.contains(browser.rawValue) }

    /// The bundled helper the manifests point at. `nil` if the app somehow shipped without it.
    var hostExecutableURL: URL? { Bundle.main.url(forAuxiliaryExecutable: "CloakDropNativeHost") }

    /// Whether the helper is present at all — drives whether the UI can offer installation.
    var isHostAvailable: Bool { hostExecutableURL != nil }

    /// The manifest body for `browser`, pointing at the helper at `hostPath`.
    func manifest(for browser: Browser, hostPath: String) -> [String: Any] {
        var manifest: [String: Any] = [
            "name": Self.hostName,
            "description": "CloakDrop native messaging host",
            "path": hostPath,
            "type": "stdio"
        ]
        if browser.isGecko {
            manifest["allowed_extensions"] = [Self.firefoxAddonID]
        } else {
            manifest["allowed_origins"] = ["chrome-extension://\(Self.chromeExtensionID)/"]
        }
        return manifest
    }

    // MARK: Install / uninstall

    /// Write the manifest for `browser`, prompting for folder access if we don't already hold a
    /// grant. Returns `false` if the user cancelled the access prompt; throws on real failures.
    @discardableResult
    func install(_ browser: Browser) throws -> Bool {
        guard let hostURL = hostExecutableURL else { throw InstallError.hostExecutableMissing }
        guard let base = resolvedBookmark(for: browser) ?? promptForSupportFolder(browser) else {
            return false // user cancelled
        }
        let scoped = base.startAccessingSecurityScopedResource()
        defer { if scoped { base.stopAccessingSecurityScopedResource() } }

        do {
            let hostsDir = base.lastPathComponent == "NativeMessagingHosts"
                ? base
                : base.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            try FileManager.default.createDirectory(at: hostsDir, withIntermediateDirectories: true)
            let file = hostsDir.appendingPathComponent("\(Self.hostName).json")
            let data = try JSONSerialization.data(
                withJSONObject: manifest(for: browser, hostPath: hostURL.path),
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: file, options: .atomic)
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }

        storeBookmark(base, for: browser)
        installed.insert(browser.rawValue)
        persistInstalled()
        return true
    }

    /// Remove the manifest if we still hold access, and always clear our record. Best-effort: a
    /// stale/absent bookmark just clears the flag (the file, if any, is harmless and inert).
    func uninstall(_ browser: Browser) {
        if let base = resolvedBookmark(for: browser) {
            let scoped = base.startAccessingSecurityScopedResource()
            defer { if scoped { base.stopAccessingSecurityScopedResource() } }
            let hostsDir = base.lastPathComponent == "NativeMessagingHosts"
                ? base
                : base.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            try? FileManager.default.removeItem(at: hostsDir.appendingPathComponent("\(Self.hostName).json"))
        }
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKeyPrefix + browser.rawValue)
        installed.remove(browser.rawValue)
        persistInstalled()
    }

    // MARK: Folder access

    /// Ask the user to grant access to the browser's support folder, starting the panel there.
    private func promptForSupportFolder(_ browser: Browser) -> URL? {
        let start = Self.realApplicationSupport().appendingPathComponent(browser.supportSubpath, isDirectory: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = start
        panel.prompt = "Grant Access"
        panel.message = "Grant CloakDrop access to \(browser.displayName)’s support folder so it can install the browser integration."
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func resolvedBookmark(for browser: Browser) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKeyPrefix + browser.rawValue) else {
            return nil
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), !stale else {
            return nil
        }
        return url
    }

    private func storeBookmark(_ url: URL, for browser: Browser) {
        guard let data = try? url.bookmarkData(options: [.withSecurityScope]) else { return }
        UserDefaults.standard.set(data, forKey: Self.bookmarkKeyPrefix + browser.rawValue)
    }

    private func persistInstalled() {
        UserDefaults.standard.set(Array(installed), forKey: Self.installedKey)
    }

    /// The *real* `~/Library/Application Support`. Inside the sandbox, `FileManager`'s search paths
    /// and `NSHomeDirectory()` point at the container, so we read the real home from the password
    /// database (`getpwuid`) to escape it — the open panel needs a real starting location.
    private static func realApplicationSupport() -> URL {
        let home: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = String(cString: dir)
        } else {
            home = NSHomeDirectory()
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}
