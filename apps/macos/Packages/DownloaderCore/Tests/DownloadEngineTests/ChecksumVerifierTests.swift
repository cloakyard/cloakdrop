import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadEngine

@Suite("Checksum verifier")
struct ChecksumVerifierTests {
    private func writeTempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloakdrop-checksum-\(UUID().uuidString)")
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    @Test("Computes known digests for 'hello'")
    func knownDigests() async throws {
        let url = try writeTempFile("hello")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try await ChecksumVerifier.hash(fileURL: url, algorithm: .md5) == "5d41402abc4b2a76b9719d911017c592")
        #expect(try await ChecksumVerifier.hash(fileURL: url, algorithm: .sha1) == "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d")
        #expect(try await ChecksumVerifier.hash(fileURL: url, algorithm: .sha256) == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    @Test("verify() passes on a match and throws on a mismatch")
    func verifyMatch() async throws {
        let url = try writeTempFile("hello")
        defer { try? FileManager.default.removeItem(at: url) }

        let good = ChecksumExpectation(algorithm: .sha256, expectedHex: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        await #expect(throws: Never.self) { try await ChecksumVerifier.verify(fileURL: url, against: good) }

        let bad = ChecksumExpectation(algorithm: .sha256, expectedHex: String(repeating: "0", count: 64))
        await #expect(throws: DownloadError.self) { try await ChecksumVerifier.verify(fileURL: url, against: bad) }
    }

    @Test("Chunked hashing matches regardless of chunk size")
    func chunkInvariance() async throws {
        let big = String(repeating: "CloakDrop-", count: 100_000)
        let url = try writeTempFile(big)
        defer { try? FileManager.default.removeItem(at: url) }

        let whole = try await ChecksumVerifier.hash(fileURL: url, algorithm: .sha256, chunkSize: 1 << 20)
        let tiny = try await ChecksumVerifier.hash(fileURL: url, algorithm: .sha256, chunkSize: 7)
        #expect(whole == tiny)
    }
}
