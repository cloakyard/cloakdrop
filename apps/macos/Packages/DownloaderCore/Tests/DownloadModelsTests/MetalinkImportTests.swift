import Foundation
import Testing
@testable import DownloadModels

@Suite("Metalink → download mapping")
struct MetalinkImportTests {
    private func file(name: String = "ubuntu.iso",
                      sources: [(String, Int)],
                      checksum: ChecksumExpectation? = nil) -> MetalinkFile {
        MetalinkFile(
            name: name,
            sources: sources.map { MetalinkSource(url: URL(string: $0.0)!, priority: $0.1) },
            checksum: checksum
        )
    }

    @Test("Request takes the strongest source as primary and the rest as mirrors")
    func mapsSourcesToPrimaryAndMirrors() {
        let f = file(sources: [
            ("https://a.example.com/x.iso", 1),
            ("https://b.example.com/x.iso", 2),
            ("https://c.example.com/x.iso", 3)
        ], checksum: ChecksumExpectation(algorithm: .sha256, expectedHex: String(repeating: "a", count: 64)))

        let req = DownloadRequest(metalink: f, destinationDirectoryPath: "/tmp")
        #expect(req?.url == URL(string: "https://a.example.com/x.iso"))
        #expect(req?.mirrors == [URL(string: "https://b.example.com/x.iso")!,
                                 URL(string: "https://c.example.com/x.iso")!])
        #expect(req?.suggestedFileName == "ubuntu.iso")
        #expect(req?.checksum?.algorithm == .sha256)
    }

    @Test("One request per file; a source-less entry is dropped")
    func requestsPerFile() {
        let files = [
            file(name: "a.bin", sources: [("https://a.example.com/1", 1)]),
            file(name: "b.bin", sources: [("https://b.example.com/1", 1), ("https://b.example.com/2", 2)])
        ]
        let reqs = DownloadRequest.requests(fromMetalink: files, destinationDirectoryPath: "/tmp")
        #expect(reqs.count == 2)
        #expect(reqs[0].mirrors.isEmpty)
        #expect(reqs[1].mirrors.count == 1)
    }
}

@Suite("Download transfer sources")
struct TransferSourcesTests {
    @Test("Primary first, then mirrors, de-duplicated")
    func orderAndDedup() {
        let primary = URL(string: "https://a.example.com/x")!
        let b = URL(string: "https://b.example.com/x")!
        let d = Download(url: primary, mirrors: [b, primary, b], fileName: "x", destinationDirectoryPath: "/tmp")
        #expect(d.transferSources == [primary, b])
    }

    @Test("No mirrors → just the primary")
    func singleSource() {
        let primary = URL(string: "https://a.example.com/x")!
        let d = Download(url: primary, fileName: "x", destinationDirectoryPath: "/tmp")
        #expect(d.transferSources == [primary])
    }
}
