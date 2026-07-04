import Foundation
import Testing
@testable import DownloadModels

@Suite("Page link extractor")
struct PageLinkExtractorTests {
    private let base = URL(string: "https://example.com/dir/page.html")!

    private let html = """
    <html><body>
      <a href="file1.zip">rel</a>
      <a href='/downloads/file2.pdf'>abs path</a>
      <a href="https://cdn.example.com/file3.zip">abs url</a>
      <img src="images/pic.png">
      <a href="#section">anchor</a>
      <a href="javascript:void(0)">js</a>
      <a href="mailto:a@b.com">mail</a>
      <a href="file1.zip">dup</a>
      <a href="ftp://ftp.example.com/pub/data.iso">ftp</a>
    </body></html>
    """

    @Test("Resolves relative and absolute links, keeps http/ftp, drops junk, dedupes")
    func extractsAndResolves() {
        let urls = PageLinkExtractor.extract(html: html, baseURL: base).map(\.absoluteString)
        #expect(urls.contains("https://example.com/dir/file1.zip"))     // relative → resolved
        #expect(urls.contains("https://example.com/downloads/file2.pdf")) // root-relative
        #expect(urls.contains("https://cdn.example.com/file3.zip"))      // absolute
        #expect(urls.contains("https://example.com/dir/images/pic.png")) // img src
        #expect(urls.contains("ftp://ftp.example.com/pub/data.iso"))     // ftp kept
        #expect(!urls.contains { $0.contains("#section") })              // anchor dropped
        #expect(!urls.contains { $0.contains("javascript") })            // js dropped
        #expect(!urls.contains { $0.contains("mailto") })                // mail dropped
        #expect(urls.filter { $0.hasSuffix("dir/file1.zip") }.count == 1) // deduped
    }

    @Test("Extension filter narrows to a single type")
    func filtersByExtension() {
        let zips = PageLinkExtractor.extract(html: html, baseURL: base, extensions: ["zip"]).map(\.absoluteString)
        #expect(zips.allSatisfy { $0.hasSuffix(".zip") })
        #expect(zips.count == 2)   // file1.zip + file3.zip
    }

    @Test("Decodes &amp; entities and keeps links whose paths contain spaces")
    func entitiesAndSpaces() {
        let html = """
        <a href="dl.php?a=1&amp;b=2">entity</a>
        <a href="My Big File.zip">space</a>
        """
        let urls = PageLinkExtractor.extract(html: html, baseURL: base).map(\.absoluteString)
        #expect(urls.contains { $0.contains("a=1&b=2") })          // &amp; decoded, not &amp;b
        #expect(!urls.contains { $0.contains("amp;") })
        #expect(urls.contains { $0.contains("My%20Big%20File.zip") }) // space link kept (percent-encoded)
    }

    @Test("Reports the distinct extensions present")
    func availableExtensions() {
        let exts = PageLinkExtractor.availableExtensions(html: html, baseURL: base)
        #expect(exts.contains("zip"))
        #expect(exts.contains("pdf"))
        #expect(exts.contains("png"))
        #expect(exts.contains("iso"))
    }
}
