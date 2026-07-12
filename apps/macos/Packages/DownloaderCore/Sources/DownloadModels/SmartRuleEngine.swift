import Foundation

/// Evaluates a prospective download against the user's `SmartRule`s and folds the winning rule's
/// actions into the request. Pure and I/O-free: it reasons over values only, so it runs on the main
/// actor at add time and is exhaustively unit-tested. This is the crown of the on-device intake —
/// it uses the link-intelligence pre-flight (MIME/size) without a single extra network call.
public enum SmartRuleEngine {

    /// The first enabled rule — in `order` — whose conditions all match `input`, or `nil` if none do.
    /// Only one rule ever applies, so rules are a priority list, not a pile of overlapping effects.
    public static func firstMatch(for input: RuleInput, in rules: [SmartRule]) -> SmartRule? {
        rules
            .filter(\.isEnabled)
            .sorted { $0.order < $1.order }
            .first { $0.matches(input) }
    }

    /// Return `request` with `rule`'s actions applied (destination, queue, speed cap, auto-start).
    /// Actions apply in order; for two of the same kind the last wins.
    public static func apply(_ rule: SmartRule, to request: DownloadRequest) -> DownloadRequest {
        var result = request
        for action in rule.actions {
            switch action {
            case .setDestination(let path, let bookmark):
                result.destinationDirectoryPath = path
                result.destinationBookmark = bookmark
            case .assignQueue(let id):
                result.queueID = id
            case .limitSpeed(let bytesPerSecond):
                result.speedLimitBytesPerSecond = bytesPerSecond
            case .autoStart(let start):
                result.startImmediately = start
            }
        }
        return result
    }

    /// Convenience: find the first matching rule and apply it, returning the (possibly unchanged)
    /// request alongside the rule that fired (`nil` when nothing matched).
    public static func resolve(
        _ request: DownloadRequest,
        input: RuleInput,
        rules: [SmartRule]
    ) -> (request: DownloadRequest, matched: SmartRule?) {
        guard let rule = firstMatch(for: input, in: rules) else { return (request, nil) }
        return (apply(rule, to: request), rule)
    }
}
