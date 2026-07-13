import Foundation
import Testing
@testable import DownloadModels

@Suite("Signature assessment + unified trust level")
struct SignatureTrustTests {

    private func completed(checksumVerified: Bool? = nil, signature: SignatureAssessment? = nil) -> Download {
        var download = Download(url: URL(string: "https://host.example/app.dmg")!, fileName: "app.dmg", destinationDirectoryPath: "/tmp")
        download.status = .completed
        download.checksumVerified = checksumVerified
        download.signature = signature
        return download
    }

    // MARK: Assessability

    @Test("Only installable types are assessed")
    func assessableTypes() {
        #expect(SignatureAssessment.isAssessable(fileName: "App.dmg"))
        #expect(SignatureAssessment.isAssessable(fileName: "Some.App"))   // case-insensitive
        #expect(!SignatureAssessment.isAssessable(fileName: "movie.mp4"))
        #expect(!SignatureAssessment.isAssessable(fileName: "installer.pkg"))  // deferred: CMS, not SecStaticCode
        #expect(!SignatureAssessment.isAssessable(fileName: "archive.zip"))
    }

    // MARK: Unified trust level (checksum + signature)

    @Test("A matched checksum or a valid signature reads as verified")
    func verified() {
        #expect(completed(checksumVerified: true).trustLevel == .verified)
        #expect(completed(signature: SignatureAssessment(status: .valid)).trustLevel == .verified)
        #expect(completed(checksumVerified: true, signature: SignatureAssessment(status: .valid)).trustLevel == .verified)
    }

    @Test("A checksum mismatch or an invalid signature reads as warning")
    func warning() {
        #expect(completed(checksumVerified: false).trustLevel == .warning)
        #expect(completed(signature: SignatureAssessment(status: .invalid)).trustLevel == .warning)
    }

    @Test("A negative signal always outranks a positive one")
    func negativeWins() {
        // Valid signature but a failed checksum → still a warning (a failure is never masked).
        #expect(completed(checksumVerified: false, signature: SignatureAssessment(status: .valid)).trustLevel == .warning)
        // Matched checksum but an invalid signature → warning.
        #expect(completed(checksumVerified: true, signature: SignatureAssessment(status: .invalid)).trustLevel == .warning)
    }

    @Test("Nothing to vouch for reads as unknown")
    func unknown() {
        #expect(completed().trustLevel == .unknown)
        #expect(completed(signature: SignatureAssessment(status: .unsigned)).trustLevel == .unknown)
    }
}
