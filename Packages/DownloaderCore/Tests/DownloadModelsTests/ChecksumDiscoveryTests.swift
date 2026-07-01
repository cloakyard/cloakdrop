import Foundation
import Testing
@testable import DownloadModels

@Suite("Checksum auto-discovery (sibling URL derivation + file parsing)")
struct ChecksumDiscoveryTests {
    private let sha256 = String(repeating: "a", count: 64)
    private let sha1 = String(repeating: "b", count: 40)
    private let md5 = String(repeating: "c", count: 32)

    // MARK: Sibling candidates

    @Test("Candidates append a checksum extension, strongest first, dropping the query")
    func siblingCandidates() {
        let url = URL(string: "https://host.example/files/app.dmg?token=xyz#frag")!
        let candidates = ChecksumDiscovery.siblingCandidates(for: url)
        #expect(candidates.map(\.algorithm) == [.sha256, .sha1, .md5])
        #expect(candidates.map { $0.url.absoluteString } == [
            "https://host.example/files/app.dmg.sha256",
            "https://host.example/files/app.dmg.sha1",
            "https://host.example/files/app.dmg.md5"
        ])
    }

    @Test("A URL with no file component yields no candidates")
    func siblingCandidatesForDirectory() {
        #expect(ChecksumDiscovery.siblingCandidates(for: URL(string: "https://host.example/dir/")!).isEmpty)
        #expect(ChecksumDiscovery.siblingCandidates(for: URL(string: "https://host.example")!).isEmpty)
    }

    // MARK: Parsing

    @Test("A bare digest is accepted")
    func parseBareDigest() {
        let result = ChecksumDiscovery.parse("\(sha256)\n", algorithm: .sha256, fileName: "app.dmg")
        #expect(result?.expectedHex == sha256)
        #expect(result?.algorithm == .sha256)
    }

    @Test("coreutils '<hex>  name' matches by file name, text and binary mode")
    func parseCoreutils() {
        #expect(ChecksumDiscovery.parse("\(sha256)  app.dmg", algorithm: .sha256, fileName: "app.dmg")?.expectedHex == sha256)
        // Binary-mode asterisk.
        #expect(ChecksumDiscovery.parse("\(sha256) *app.dmg", algorithm: .sha256, fileName: "app.dmg")?.expectedHex == sha256)
        // A path in the listing still matches on the last component.
        #expect(ChecksumDiscovery.parse("\(sha256)  ./dist/app.dmg", algorithm: .sha256, fileName: "app.dmg")?.expectedHex == sha256)
    }

    @Test("A multi-file SUMS listing picks the matching name and rejects when none match")
    func parseMultiFile() {
        let other = String(repeating: "d", count: 64)
        let doc = """
        # generated sums
        \(other)  other.zip
        \(sha256)  app.dmg
        """
        #expect(ChecksumDiscovery.parse(doc, algorithm: .sha256, fileName: "app.dmg")?.expectedHex == sha256)
        // No line matches "missing.dmg", and there are several entries → ambiguous → nil.
        #expect(ChecksumDiscovery.parse(doc, algorithm: .sha256, fileName: "missing.dmg") == nil)
    }

    @Test("BSD/OpenSSL 'ALGO (name) = <hex>' is understood")
    func parseBSD() {
        let line = "SHA256 (app.dmg) = \(sha256)"
        #expect(ChecksumDiscovery.parse(line, algorithm: .sha256, fileName: "app.dmg")?.expectedHex == sha256)
    }

    @Test("A single mismatched-name entry is still used (a per-file sibling belongs to the download)")
    func parseLoneDigestFallback() {
        // One entry whose listed name differs (e.g. the file was renamed on save) → trust it.
        #expect(ChecksumDiscovery.parse("\(sha256)  original-name.dmg", algorithm: .sha256, fileName: "renamed.dmg")?.expectedHex == sha256)
    }

    @Test("Wrong-length or non-hex content is rejected")
    func parseRejectsMalformed() {
        #expect(ChecksumDiscovery.parse("not-a-hash", algorithm: .sha256, fileName: "app.dmg") == nil)
        #expect(ChecksumDiscovery.parse(String(repeating: "a", count: 63), algorithm: .sha256, fileName: "app.dmg") == nil)
        // A valid MD5-length digest is not a valid SHA-256.
        #expect(ChecksumDiscovery.parse(md5, algorithm: .sha256, fileName: "app.dmg") == nil)
        #expect(ChecksumDiscovery.parse("", algorithm: .sha256, fileName: "app.dmg") == nil)
    }

    @Test("MD5 and SHA-1 digests parse at their own lengths")
    func parseOtherAlgorithms() {
        #expect(ChecksumDiscovery.parse("\(md5)  app.dmg", algorithm: .md5, fileName: "app.dmg")?.expectedHex == md5)
        #expect(ChecksumDiscovery.parse("\(sha1)  app.dmg", algorithm: .sha1, fileName: "app.dmg")?.expectedHex == sha1)
    }
}
