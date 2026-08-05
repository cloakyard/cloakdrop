import Foundation
import Testing
@testable import DownloadEngine

@Suite("Quarantine flag")
struct QuarantineTests {
    private func makeTempFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloakdrop-quarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("download.bin")
        try Data("payload".utf8).write(to: file)
        return file
    }

    @Test("A finished file is stamped with the com.apple.quarantine flag")
    func stampsQuarantine() throws {
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        // Not quarantined until we stamp it.
        #expect(Quarantine.isQuarantined(path: file.path) == false)

        Quarantine.apply(toPath: file.path,
                         sourceURL: URL(string: "https://example.com/download.bin"),
                         originURL: URL(string: "https://example.com/page"))

        #expect(Quarantine.isQuarantined(path: file.path) == true)

        // The value carries CloakDrop as the agent and is not "user-approved" (flags start 0001,
        // without the 0x40 bit), so Gatekeeper still vets it on first open.
        var buffer = [CChar](repeating: 0, count: 256)
        let length = getxattr(file.path, Quarantine.attributeName, &buffer, buffer.count, 0, 0)
        try #require(length > 0)
        let value = try #require(buffer.withUnsafeBytes { raw in
            String(bytes: raw.prefix(length), encoding: .utf8)
        })
        #expect(value.hasPrefix("0001;"))
        #expect(value.contains("CloakDrop"))
    }
}
