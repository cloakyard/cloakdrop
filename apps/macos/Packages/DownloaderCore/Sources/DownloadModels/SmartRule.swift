import Foundation

/// The facts about a prospective download that a `SmartRule` matches against. Built from the add
/// request, enriched — when a pre-flight ran — with the resource's MIME type and size.
public struct RuleInput: Sendable, Hashable {
    public var url: URL
    public var fileName: String
    public var category: FileCategory
    /// The resource's MIME type from a pre-flight probe, if one was made.
    public var mimeType: String?
    /// The resource's size from a pre-flight probe, if known.
    public var sizeBytes: Int64?

    public init(url: URL, fileName: String, category: FileCategory, mimeType: String? = nil, sizeBytes: Int64? = nil) {
        self.url = url
        self.fileName = fileName
        self.category = category
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
    }
}

/// One predicate over a prospective download. A rule's conditions are combined with AND, so each
/// must hold for the rule to fire. Text comparisons are case-insensitive; size comparisons never
/// match when the size is unknown (no probe ran), so a size rule can't fire on a guess.
public enum SmartRuleCondition: Sendable, Hashable, Codable {
    case urlHostContains(String)
    case urlContains(String)
    case fileNameContains(String)
    /// The file's extension is one of these (compared lowercased, without the dot).
    case fileExtensionIn([String])
    case mimeTypeContains(String)
    case categoryIs(FileCategory)
    case largerThan(Int64)
    case smallerThan(Int64)

    public func matches(_ input: RuleInput) -> Bool {
        switch self {
        case .urlHostContains(let value):
            return contains(input.url.host(), value)
        case .urlContains(let value):
            return contains(input.url.absoluteString, value)
        case .fileNameContains(let value):
            return contains(input.fileName, value)
        case .fileExtensionIn(let extensions):
            let ext = (input.fileName as NSString).pathExtension.lowercased()
            return !ext.isEmpty && extensions.contains { $0.lowercased() == ext }
        case .mimeTypeContains(let value):
            return contains(input.mimeType, value)
        case .categoryIs(let category):
            return input.category == category
        case .largerThan(let bytes):
            guard let size = input.sizeBytes else { return false }
            return size > bytes
        case .smallerThan(let bytes):
            guard let size = input.sizeBytes else { return false }
            return size < bytes
        }
    }

    /// Case-insensitive substring test that's `false` for a nil haystack or an empty needle (an
    /// empty needle would otherwise match everything and make a rule a silent catch-all).
    private func contains(_ haystack: String?, _ needle: String) -> Bool {
        let needle = needle.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty, let haystack else { return false }
        return haystack.lowercased().contains(needle)
    }
}

/// What to do to a matched download before it's committed. Applied in order; for two actions of the
/// same kind the last one wins.
public enum SmartRuleAction: Sendable, Hashable, Codable {
    /// Route the download into this folder (with its security-scoped bookmark, for the sandbox).
    case setDestination(path: String, bookmark: Data?)
    /// Put the download in this queue.
    case assignQueue(UUID)
    /// Cap this download's speed (bytes/sec).
    case limitSpeed(bytesPerSecond: Int64)
    /// Start immediately (`true`) or hold the download paused (`false`).
    case autoStart(Bool)
}

/// A user-defined, on-device routing rule: "when a download matches these conditions, do these
/// things to it." Evaluated entirely locally at add time — no network, no telemetry.
public struct SmartRule: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var isEnabled: Bool
    /// Evaluation order; lower fires first. Only the first matching enabled rule applies.
    public var order: Int
    /// Combined with AND. An empty set matches every download (a catch-all).
    public var conditions: [SmartRuleCondition]
    public var actions: [SmartRuleAction]

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        order: Int = 0,
        conditions: [SmartRuleCondition] = [],
        actions: [SmartRuleAction] = []
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.order = order
        self.conditions = conditions
        self.actions = actions
    }

    /// Whether every condition holds for `input` (vacuously true when there are no conditions).
    public func matches(_ input: RuleInput) -> Bool {
        conditions.allSatisfy { $0.matches(input) }
    }
}
