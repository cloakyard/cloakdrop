import Foundation

/// What the app should do once every download has finished. Kept deliberately
/// sandbox-friendly: `quit` simply terminates the app (no Apple Events / system-sleep
/// entitlements). Persisted in `EngineSettings`.
public enum SchedulerPostAction: String, Sendable, Codable, CaseIterable, Identifiable {
    case none, quit

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: return "Do nothing"
        case .quit: return "Quit CloakDrop"
        }
    }
}
