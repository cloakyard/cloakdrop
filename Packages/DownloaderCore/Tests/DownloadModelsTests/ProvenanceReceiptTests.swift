import Foundation
import Testing
@testable import DownloadModels

@Suite("Provenance receipt")
struct ProvenanceReceiptTests {
    private func receipt(
        secure: Bool = true,
        checksumVerified: Bool? = true,
        signature: SignatureAssessment? = nil,
        trust: TrustLevel = .verified
    ) -> ProvenanceReceipt {
        ProvenanceReceipt(
            fileName: "app.dmg",
            fileSizeBytes: 123_456,
            sourceURL: URL(string: "https://dl.example.com/app.dmg")!,
            finalURL: URL(string: "https://cdn.example.com/app.dmg")!,
            mirrors: [URL(string: "https://mirror.example.org/app.dmg")!],
            transportSecure: secure,
            sha256: String(repeating: "a", count: 64),
            expectedChecksum: ChecksumExpectation(algorithm: .sha256, expectedHex: String(repeating: "a", count: 64)),
            checksumVerified: checksumVerified,
            signature: signature,
            trustLevel: trust,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test("Export includes source, resolved URL, mirrors, hash, and verdicts")
    func exportContents() {
        let text = receipt(signature: SignatureAssessment(status: .valid, authority: "Developer ID: Acme")).exportText()
        #expect(text.contains("Source:      https://dl.example.com/app.dmg"))
        #expect(text.contains("Resolved to: https://cdn.example.com/app.dmg"))
        #expect(text.contains("mirror.example.org"))
        #expect(text.contains("Transport:   encrypted (TLS)"))
        #expect(text.contains("SHA-256:     " + String(repeating: "a", count: 64)))
        #expect(text.contains("SHA-256 — matched"))
        #expect(text.contains("Signature:   valid (Developer ID: Acme)"))
        #expect(text.contains("Trust:       verified"))
    }

    @Test("A checksum mismatch is spelled out and cleartext transport is flagged")
    func mismatchAndCleartext() {
        let text = receipt(secure: false, checksumVerified: false, trust: .warning).exportText()
        #expect(text.contains("SHA-256 — MISMATCH"))
        #expect(text.contains("Transport:   cleartext"))
        #expect(text.contains("Trust:       warning"))
    }

    @Test("Receipt round-trips through Codable")
    func codableRoundTrip() throws {
        let original = receipt(signature: SignatureAssessment(status: .valid))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProvenanceReceipt.self, from: data)
        #expect(decoded == original)
    }
}
