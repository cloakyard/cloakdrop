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

    @Test("containsPattern detects range syntax")
    func detect() {
        #expect(URLBatch.containsPattern("a[1-9].zip"))
        #expect(!URLBatch.containsPattern("a1.zip"))
    }
}
