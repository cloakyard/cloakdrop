import ServiceManagement

/// The app's "Open at Login" registration, via `SMAppService` — the sandbox-safe modern login-item
/// API (the successor to `SMLoginItemSetEnabled`). The OS owns the state: it persists the
/// registration across launches and mirrors it in System Settings ▸ General ▸ Login Items, so this
/// is a thin, stateless adapter rather than something that keeps a duplicate flag of its own.
struct LoginItemService {
    /// Whether CloakDrop is currently registered to open at login.
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// The user turned the item off in System Settings; re-enabling it needs their approval there
    /// (`register()` alone can't override an explicit user opt-out).
    var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Register or unregister the app as a login item. Idempotent (a no-op when already in the
    /// requested state) and throws if the OS rejects the change — e.g. an unsigned/ad-hoc build.
    func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }

    /// Reveal the Login Items pane in System Settings, to guide the user when re-enabling requires
    /// their approval.
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
