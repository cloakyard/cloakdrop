import Foundation
import Testing
@testable import DownloadModels

@Suite("URL batch parsing & pattern expansion")
struct URLBatchTests {

    @Test("Numeric pattern expands with zero-padding preserved")
    func numericPadded() {
        let urls = URLBatch.expand("https://e.com/file[01-50].zip")
        #expect(urls.count == 50)
        #expect(urls.first?.absoluteString == "https://e.com/file01.zip")
        #expect(urls.last?.absoluteString == "https://e.com/file50.zip")
    }

    @Test("Unpadded numeric pattern stays unpadded")
    func numericUnpadded() {
        let urls = URLBatch.expand("https://e.com/p[1-3]/x.bin")
        #expect(urls.map(\.absoluteString) == [
            "https://e.com/p1/x.bin",
            "https://e.com/p2/x.bin",
            "https://e.com/p3/x.bin"
        ])
    }

    @Test("A huge numeric range is bounded before value allocation")
    func hugeNumericRange() {
        let urls = URLBatch.expand("https://e.com/p[0-999999999].bin")
        #expect(urls.count == URLBatch.expansionLimit)
        #expect(urls.last?.path == "/p9999.bin")
    }

    @Test("Thousands of singleton patterns are rejected at the bounded depth limit")
    func singletonPatternDepth() {
        let groups = String(repeating: "[1-1]", count: 2_000)
        #expect(URLBatch.expand("https://e.com/\(groups).bin").isEmpty)
    }

    @Test("One oversized token is dropped without hiding the following URL")
    func tokenByteLimit() {
        let oversized = "https://e.com/" + String(repeating: "x", count: URLBatch.maximumTokenBytes)
        #expect(URLBatch.expand(oversized).isEmpty)
        let parsed = URLBatch.parse(oversized + "\nhttps://e.com/ok.bin")
        #expect(parsed.map(\.absoluteString) == ["https://e.com/ok.bin"])
    }

    @Test("A long suffix cannot amplify expansion beyond the aggregate byte budget")
    func aggregateExpansionBytes() {
        let suffix = String(repeating: "x", count: 2_048)
        let urls = URLBatch.expand("https://e.com/item-[0-9999].bin?padding=\(suffix)")
        let bytes = urls.reduce(into: 0) { $0 += $1.absoluteString.utf8.count }
        #expect(!urls.isEmpty)
        #expect(urls.count < URLBatch.expansionLimit)
        #expect(bytes <= URLBatch.maximumExpandedBytes)
    }

    @Test("Alpha range expands letter by letter")
    func alpha() {
        let urls = URLBatch.expand("https://e.com/img-[a-d].png")
        #expect(urls.map { $0.lastPathComponent } == ["img-a.png", "img-b.png", "img-c.png", "img-d.png"])
    }

    @Test("Multiple groups expand as a cartesian product")
    func cartesian() {
        let urls = URLBatch.expand("https://e.com/[1-2]/[a-b].txt")
        #expect(urls.map(\.path) == ["/1/a.txt", "/1/b.txt", "/2/a.txt", "/2/b.txt"])
    }

    @Test("Plain URL without a pattern returns itself")
    func plain() {
        let urls = URLBatch.expand("https://e.com/file.zip")
        #expect(urls.count == 1)
    }

    @Test("Bare host gets an https scheme; non-host words are rejected")
    func bareHost() {
        #expect(URLBatch.normalized("example.com/a.zip")?.scheme == "https")
        #expect(URLBatch.normalized("localhost:8080/a.zip")?.scheme == "https")
        #expect(URLBatch.normalized("not a url") == nil)
        // A schemeless single word with no dot is not a host — must be dropped, not turned
        // into https://notes.
        #expect(URLBatch.normalized("notes") == nil)
        #expect(URLBatch.normalized("not_a_url_but_no_dot") == nil)
    }

    @Test("Cross-case alpha range is rejected, not expanded into punctuation")
    func crossCaseAlphaIsNotGarbage() {
        // The scalar span A...z includes `[ \ ] ^ _ \`` — a naive expansion would emit six
        // junk URLs. The pattern must be treated as a literal instead.
        let urls = URLBatch.expand("https://e.com/x[A-z].png")
        #expect(urls.count <= 1)
        #expect(!urls.contains { $0.absoluteString.contains("\\") || $0.absoluteString.contains("^") })
    }

    @Test("Parsing a pasted list dedupes and drops invalid lines")
    func parseList() {
        let text = """
        https://e.com/a.zip
        https://e.com/a.zip
        e.com/b.zip

        not_a_url_but_no_dot
        ftp://e.com/c.zip
        """
        let urls = URLBatch.parse(text)
        let strings = urls.map(\.absoluteString)
        #expect(strings.contains("https://e.com/a.zip"))
        #expect(strings.contains("https://e.com/b.zip"))
        #expect(strings.filter { $0 == "https://e.com/a.zip" }.count == 1)   // deduped
        #expect(strings.contains("ftp://e.com/c.zip"))                        // FTP is now supported
        #expect(!strings.contains { $0.contains("not_a_url_but_no_dot") })    // junk dropped
    }

    @Test("Parsing expands patterns embedded in a list")
    func parseWithPatterns() {
        let urls = URLBatch.parse("https://e.com/v[1-3].mp4")
        #expect(urls.count == 3)
    }

    @Test("The output ceiling applies across an entire pasted batch")
    func parseLimitIsGlobal() {
        let text = "https://a.example/v[0-9999].mp4\nhttps://b.example/v[0-9999].mp4"
        let urls = URLBatch.parse(text)
        #expect(urls.count == URLBatch.expansionLimit)
        #expect(urls.allSatisfy { $0.host == "a.example" })
    }

    @Test("Cancellable parsing stops before expanding obsolete work")
    func cancellation() async {
        let parse = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try URLBatch.parseCancellable("https://e.com/v[0-9999].mp4")
        }
        do {
            _ = try await parse.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("UTF-8 input capping drops a split scalar without inserting replacement bytes")
    func validUTF8Boundary() {
        let text = "1234567😀tail"
        let split = URLBatch.boundedInput(text, maximumUTF8Bytes: 8)
        #expect(split == "1234567")
        #expect(split.utf8.count <= 8)
        #expect(!split.contains("�"))
        #expect(URLBatch.boundedInput(text, maximumUTF8Bytes: 11) == "1234567😀")
    }

    @Test("containsPattern detects range syntax")
    func detect() {
        #expect(URLBatch.containsPattern("a[1-9].zip"))
        #expect(!URLBatch.containsPattern("a1.zip"))
    }
}
