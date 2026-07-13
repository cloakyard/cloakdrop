import Foundation

/// What the app should do once every download has finished. Kept deliberately sandbox-friendly:
/// nothing here needs Apple Events or system-sleep entitlements. `quit` terminates the app; `notify`
/// posts a local "all done" notification; `runShortcut` opens a user-chosen Shortcut via the
/// `shortcuts://` URL scheme — which lets the user wire up sleep / shutdown / "move files" / anything
/// without CloakDrop itself holding a single extra privilege. Persisted in `EngineSettings` (the
/// Shortcut's name lives alongside it in `EngineSettings.postCompletionShortcutName`).
public enum SchedulerPostAction: String, Sendable, Codable, CaseIterable, Identifiable {
    case none, notify, quit, runShortcut

    public var id: String { rawValue }

    /// Whether choosing this action requires a Shortcut name to be supplied.
    public var needsShortcutName: Bool { self == .runShortcut }

    public var label: String {
        switch self {
        case .none: return "Do nothing"
        case .notify: return "Show a notification"
        case .quit: return "Quit CloakDrop"
        case .runShortcut: return "Run a Shortcut"
        }
    }
}
