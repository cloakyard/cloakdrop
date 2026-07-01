import Foundation
import Testing
@testable import DownloadModels

@Suite("Smart rules (conditions, matching, engine)")
struct SmartRuleTests {

    private func input(
        url: String = "https://cdn.example.com/files/movie.mkv",
        fileName: String = "movie.mkv",
        mime: String? = nil,
        size: Int64? = nil
    ) -> RuleInput {
        RuleInput(
            url: URL(string: url)!,
            fileName: fileName,
            category: FileCategory.classify(fileName: fileName),
            mimeType: mime,
            sizeBytes: size
        )
    }

    // MARK: Conditions

    @Test("Text conditions match case-insensitively; an empty needle never matches")
    func textConditions() {
        let base = input()
        #expect(SmartRuleCondition.urlHostContains("CDN.example").matches(base))
        #expect(SmartRuleCondition.urlContains("/files/").matches(base))
        #expect(SmartRuleCondition.fileNameContains("MOVIE").matches(base))
        #expect(!SmartRuleCondition.fileNameContains("").matches(base))       // empty → no match
        #expect(!SmartRuleCondition.urlHostContains("other.com").matches(base))
    }

    @Test("Extension and category conditions")
    func extensionAndCategory() {
        let base = input()
        #expect(SmartRuleCondition.fileExtensionIn(["MKV", "mp4"]).matches(base))   // case-insensitive
        #expect(!SmartRuleCondition.fileExtensionIn(["zip"]).matches(base))
        #expect(SmartRuleCondition.categoryIs(.video).matches(base))
        #expect(!SmartRuleCondition.categoryIs(.archive).matches(base))
    }

    @Test("MIME conditions match only when a MIME was probed")
    func mimeConditions() {
        #expect(SmartRuleCondition.mimeTypeContains("video/").matches(input(mime: "video/x-matroska")))
        #expect(!SmartRuleCondition.mimeTypeContains("video/").matches(input(mime: nil)))     // no probe → no match
        #expect(!SmartRuleCondition.mimeTypeContains("audio/").matches(input(mime: "video/mp4")))
    }

    @Test("Size conditions never match when the size is unknown")
    func sizeConditions() {
        #expect(SmartRuleCondition.largerThan(1000).matches(input(size: 2000)))
        #expect(!SmartRuleCondition.largerThan(1000).matches(input(size: 500)))
        #expect(SmartRuleCondition.smallerThan(1000).matches(input(size: 500)))
        #expect(!SmartRuleCondition.largerThan(1000).matches(input(size: nil)))    // unknown → no match
        #expect(!SmartRuleCondition.smallerThan(1000).matches(input(size: nil)))
    }

    // MARK: Rule matching (AND)

    @Test("All conditions must hold; an empty rule is a catch-all")
    func ruleMatching() {
        let both = SmartRule(name: "big videos", conditions: [.categoryIs(.video), .largerThan(1_000_000)])
        #expect(both.matches(input(size: 2_000_000)))
        #expect(!both.matches(input(size: 10)))                 // fails the size condition
        #expect(!both.matches(input(fileName: "song.mp3", size: 2_000_000)))  // fails the category

        let catchAll = SmartRule(name: "everything", conditions: [])
        #expect(catchAll.matches(input()))
    }

    // MARK: Engine — firstMatch precedence

    @Test("The first enabled rule in order wins; disabled rules are skipped")
    func firstMatchPrecedence() {
        let byExt = SmartRule(name: "zips", order: 0, conditions: [.fileExtensionIn(["mkv"])])
        let byCategory = SmartRule(name: "videos", order: 1, conditions: [.categoryIs(.video)])
        let both = [byExt, byCategory]

        // Both match an .mkv; order 0 wins.
        #expect(SmartRuleEngine.firstMatch(for: input(), in: both)?.id == byExt.id)

        // Disable the first → the second wins.
        var disabledFirst = byExt; disabledFirst.isEnabled = false
        #expect(SmartRuleEngine.firstMatch(for: input(), in: [disabledFirst, byCategory])?.id == byCategory.id)

        // Nothing matches a document.
        #expect(SmartRuleEngine.firstMatch(for: input(fileName: "a.pdf"), in: both) == nil)
    }

    // MARK: Engine — apply

    @Test("Applying a rule folds all its actions into the request")
    func applyActions() {
        let queueID = UUID()
        let rule = SmartRule(name: "route", actions: [
            .setDestination(path: "/Movies", bookmark: Data([1, 2, 3])),
            .assignQueue(queueID),
            .limitSpeed(bytesPerSecond: 500_000),
            .autoStart(false)
        ])
        let request = DownloadRequest(url: URL(string: "https://x/y.mkv")!, destinationDirectoryPath: "/Downloads")
        let out = SmartRuleEngine.apply(rule, to: request)
        #expect(out.destinationDirectoryPath == "/Movies")
        #expect(out.destinationBookmark == Data([1, 2, 3]))
        #expect(out.queueID == queueID)
        #expect(out.speedLimitBytesPerSecond == 500_000)
        #expect(out.startImmediately == false)
    }

    @Test("resolve returns the request unchanged and no rule when nothing matches")
    func resolveNoMatch() {
        let rule = SmartRule(name: "videos", conditions: [.categoryIs(.video)])
        let request = DownloadRequest(url: URL(string: "https://x/report.pdf")!, destinationDirectoryPath: "/Downloads")
        let resolved = SmartRuleEngine.resolve(request, input: input(fileName: "report.pdf"), rules: [rule])
        #expect(resolved.matched == nil)
        #expect(resolved.request.destinationDirectoryPath == "/Downloads")
    }

    @Test("A rule is Codable (round-trips through JSON, as persisted)")
    func codableRoundTrip() throws {
        let rule = SmartRule(
            name: "archives → folder",
            order: 3,
            conditions: [.fileExtensionIn(["zip", "rar"]), .largerThan(1024)],
            actions: [.setDestination(path: "/Archives", bookmark: nil), .limitSpeed(bytesPerSecond: 1000)]
        )
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(SmartRule.self, from: data)
        #expect(decoded == rule)
    }
}
