import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadPersistence
@testable import DownloadEngine

/// A canned inspector so the finalize hook can be tested deterministically, without depending on
/// real signed fixtures being present.
struct StubSignatureInspector: CodeSignatureInspecting {
    let result: SignatureAssessment?
    func assess(fileURL: URL) -> SignatureAssessment? { result }
}

@Suite("Code-signature inspector (Security framework, in-process)")
struct CodeSignatureInspectorTests {

    @Test("A signed system binary validates and reports a signing authority")
    func validatesSystemBinary() {
        // /bin/ls ships Apple-signed on every macOS — a stable, offline fixture for a valid signature.
        let assessment = SecCodeSignatureInspector().assess(fileURL: URL(fileURLWithPath: "/bin/ls"))
        #expect(assessment?.status == .valid)
        #expect(assessment?.authority != nil)
    }

    @Test("A non-code file is never reported as validly signed")
    func nonCodeNeverValid() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cloak-notcode-\(UUID().uuidString).txt")
        try Data("just some text, not a Mach-O".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // The file carries no code signature: reported as unsigned (or, if unrecognizable, not
        // assessed). The invariant that matters is it must NEVER read as validly signed.
        let result = SecCodeSignatureInspector().assess(fileURL: tmp)
        #expect(result?.status != .valid)
    }
}

@Suite("Signature assessment in the finalize path")
struct SignatureFinalizeTests {

    private func makeManager(
        fileName: String,
        inspector: any CodeSignatureInspecting,
        assessSignatures: Bool = true
    ) async throws -> (DownloadManager, URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cloak-sig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = URL(string: "https://example.com/\(fileName)")!
        let mock = MockHTTPClient()
        mock.setResource(.init(data: Data(count: 8_000), acceptsRanges: true, suggestedFilename: fileName), for: url)
        let manager = DownloadManager(
            store: try GRDBDownloadStore.inMemory(),
            httpClient: mock,
            networkMonitor: AlwaysReachableMonitor(),
            signatureInspector: inspector
        )
        try await manager.start()
        var settings = await manager.currentSettings()
        settings.assessSignatures = assessSignatures
        settings.autoDiscoverChecksums = false   // keep the finalize path free of sibling probes
        await manager.updateSettings(settings)
        return (manager, url, directory)
    }

    private func waitForCompletion(_ manager: DownloadManager, id: UUID) async throws -> Download {
        let deadline = ContinuousClock().now + .seconds(15)
        while ContinuousClock().now < deadline {
            if let d = await manager.snapshot().downloads.first(where: { $0.id == id }), d.status == .completed {
                return d
            }
            try await Task.sleep(for: .milliseconds(15))
        }
        struct Timeout: Error {}
        throw Timeout()
    }

    @Test("A completed .dmg records the assessed signature and reads as verified")
    func recordsSignatureForInstallable() async throws {
        let stub = StubSignatureInspector(result: SignatureAssessment(
            status: .valid, authority: "Developer ID Application: Acme Inc. (AB12CD34EF)"
        ))
        let (manager, url, directory) = try await makeManager(fileName: "App.dmg", inspector: stub)
        defer { try? FileManager.default.removeItem(at: directory) }

        let added = await manager.add(DownloadRequest(url: url, suggestedFileName: "App.dmg", destinationDirectoryPath: directory.path))
        let done = try await waitForCompletion(manager, id: added.id)
        #expect(done.signature?.status == .valid)
        #expect(done.signature?.authority == "Developer ID Application: Acme Inc. (AB12CD34EF)")
        #expect(done.trustLevel == .verified)
    }

    @Test("An invalid signature on a completed .dmg reads as a warning")
    func invalidSignatureWarns() async throws {
        let stub = StubSignatureInspector(result: SignatureAssessment(status: .invalid))
        let (manager, url, directory) = try await makeManager(fileName: "Bad.dmg", inspector: stub)
        defer { try? FileManager.default.removeItem(at: directory) }

        let added = await manager.add(DownloadRequest(url: url, suggestedFileName: "Bad.dmg", destinationDirectoryPath: directory.path))
        let done = try await waitForCompletion(manager, id: added.id)
        #expect(done.signature?.status == .invalid)
        #expect(done.trustLevel == .warning)
    }

    @Test("A non-installable type is never signature-assessed")
    func skipsNonInstallable() async throws {
        // Even though the stub would return a signature, a .bin isn't an assessable type.
        let stub = StubSignatureInspector(result: SignatureAssessment(status: .valid))
        let (manager, url, directory) = try await makeManager(fileName: "payload.bin", inspector: stub)
        defer { try? FileManager.default.removeItem(at: directory) }

        let added = await manager.add(DownloadRequest(url: url, suggestedFileName: "payload.bin", destinationDirectoryPath: directory.path))
        let done = try await waitForCompletion(manager, id: added.id)
        #expect(done.signature == nil)
        #expect(done.trustLevel == .unknown)
    }

    @Test("Signature assessment can be turned off")
    func respectsDisabledSetting() async throws {
        let stub = StubSignatureInspector(result: SignatureAssessment(status: .valid))
        let (manager, url, directory) = try await makeManager(fileName: "App.dmg", inspector: stub, assessSignatures: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let added = await manager.add(DownloadRequest(url: url, suggestedFileName: "App.dmg", destinationDirectoryPath: directory.path))
        let done = try await waitForCompletion(manager, id: added.id)
        #expect(done.signature == nil)
    }
}
