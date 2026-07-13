import Foundation
import Testing
@testable import DownloadModels

@Suite("Metalink parser")
struct MetalinkParserTests {

    private func parse(_ xml: String) throws -> [MetalinkFile] {
        try MetalinkParser.parse(Data(xml.utf8))
    }

    private let sha256 = String(repeating: "a", count: 64)
    private let md5 = String(repeating: "b", count: 32)

    // MARK: Metalink 4 (RFC 5854)

    @Test("Parses a Metalink 4 file: name, size, priority-sorted mirrors, strongest checksum, pieces")
    func parsesMetalink4() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <metalink xmlns="urn:ietf:params:xml:ns:metalink">
          <file name="ubuntu.iso">
            <size>2048</size>
            <hash type="md5">\(md5)</hash>
            <hash type="sha-256">\(sha256)</hash>
            <pieces type="sha-256" length="1024">
              <hash>\(String(repeating: "c", count: 64))</hash>
              <hash>\(String(repeating: "d", count: 64))</hash>
            </pieces>
            <url priority="2">https://slow.example.com/ubuntu.iso</url>
            <url priority="1">https://fast.example.com/ubuntu.iso</url>
          </file>
        </metalink>
        """
        let files = try parse(xml)
        #expect(files.count == 1)
        let file = try #require(files.first)
        #expect(file.name == "ubuntu.iso")
        #expect(file.size == 2048)
        // Mirrors sorted best-first (priority 1 before 2).
        #expect(file.urls.map(\.absoluteString) == ["https://fast.example.com/ubuntu.iso", "https://slow.example.com/ubuntu.iso"])
        // SHA-256 chosen over the also-present MD5.
        #expect(file.checksum?.algorithm == .sha256)
        #expect(file.checksum?.expectedHex == sha256)
        // Piece hashes captured in order, with length + algorithm.
        #expect(file.pieceAlgorithm == .sha256)
        #expect(file.pieceLength == 1024)
        #expect(file.pieceHashes.count == 2)
        #expect(file.pieceHashes.first == String(repeating: "c", count: 64))
    }

    // MARK: Metalink 3 (legacy)

    @Test("Parses legacy Metalink 3: verification/resources layout, preference→priority, ftp dropped")
    func parsesMetalink3() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <metalink version="3.0" xmlns="http://www.metalinker.org/">
          <files>
            <file name="app.dmg">
              <size>500</size>
              <verification>
                <hash type="sha1">\(String(repeating: "e", count: 40))</hash>
              </verification>
              <resources>
                <url type="ftp" preference="100">ftp://mirror.example.com/app.dmg</url>
                <url type="http" preference="90">http://a.example.com/app.dmg</url>
                <url type="http" preference="95">http://b.example.com/app.dmg</url>
              </resources>
            </file>
          </files>
        </metalink>
        """
        let files = try parse(xml)
        let file = try #require(files.first)
        #expect(file.name == "app.dmg")
        #expect(file.checksum?.algorithm == .sha1)
        // ftp mirror dropped (engine speaks HTTP); the two http mirrors ordered by preference (95 > 90).
        #expect(file.urls.map(\.absoluteString) == ["http://b.example.com/app.dmg", "http://a.example.com/app.dmg"])
    }

    // MARK: Edge cases

    @Test("A file with no http(s) mirror is skipped, not returned as undownloadable")
    func skipsFileWithoutUsableMirror() throws {
        let xml = """
        <metalink xmlns="urn:ietf:params:xml:ns:metalink">
          <file name="only-magnet"><url>magnet:?xt=urn:btih:abc</url></file>
          <file name="real.bin"><url priority="1">https://example.com/real.bin</url></file>
        </metalink>
        """
        let files = try parse(xml)
        #expect(files.map(\.name) == ["real.bin"])
    }

    @Test("An all-zero placeholder hash is treated as no checksum")
    func ignoresPlaceholderHash() throws {
        let xml = """
        <metalink xmlns="urn:ietf:params:xml:ns:metalink">
          <file name="x.bin">
            <hash type="sha-256">\(String(repeating: "0", count: 64))</hash>
            <url priority="1">https://example.com/x.bin</url>
          </file>
        </metalink>
        """
        let file = try #require(try parse(xml).first)
        #expect(file.checksum == nil)
    }

    @Test("Malformed XML throws rather than returning garbage")
    func malformedThrows() {
        #expect(throws: (any Error).self) {
            try parse("<metalink><file name=\"x\"><url>https://e.com/x</url>")   // unclosed tags
        }
    }
}
