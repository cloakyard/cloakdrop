import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadPersistence
@testable import DownloadEngine

@Suite("Download destination safety")
struct DestinationSafetyTests {
    private struct Harness {
        let directory: URL
        let mock: MockHTTPClient
        let manager: DownloadManager

        init(resources: [URL: Data]) async throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cloakdrop-destination-safety-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            mock = MockHTTPClient()
            for (url, data) in resources {
                mock.setResource(.init(data: data, acceptsRanges: true), for: url)
            }
            manager = DownloadManager(
                store: try GRDBDownloadStore.inMemory(),
                httpClient: mock,
                networkMonitor: AlwaysReachableMonitor()
            )
            try await manager.start()
            var settings = await manager.currentSettings()
            settings.autoDiscoverChecksums = false
            settings.assessSignatures = false
            settings.applyQuarantine = false
            settings.generateProvenanceReceipts = false
            await manager.updateSettings(settings)
        }

        func waitForCompletion(_ id: UUID, timeout: Duration = .seconds(10)) async throws -> Download {
            let deadline = ContinuousClock().now + timeout
            while ContinuousClock().now < deadline {
                if let download = await manager.snapshot().downloads.first(where: { $0.id == id }) {
                    if download.status == .completed { return download }
                    if case .failed(let reason) = download.status {
                        Issue.record("download failed: \(reason)")
                        return download
                    }
                }
                try await Task.sleep(for: .milliseconds(15))
            }
            throw DestinationSafetyTimeout()
        }

        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }

    private struct DestinationSafetyTimeout: Error {}

    @Test("Engine reduces an untrusted suggested path to a destination-local basename")
    func suggestedPathTraversalIsContained() async throws {
        let url = URL(string: "https://example.com/original.bin")!
        let payload = Data((0..<32_000).map { UInt8($0 % 251) })
        let harness = try await Harness(resources: [url: payload])
        defer { harness.cleanup() }

        let uniqueName = "escaped-\(UUID().uuidString).bin"
        let unsafeSuggestion = "../../\(uniqueName)"
        let escapedPath = (harness.directory.path as NSString).appendingPathComponent(unsafeSuggestion)
        let added = await harness.manager.add(DownloadRequest(
            url: url,
            suggestedFileName: unsafeSuggestion,
            destinationDirectoryPath: harness.directory.path
        ))
        let done = try await harness.waitForCompletion(added.id)

        #expect(done.status == .completed)
        #expect(done.fileName == uniqueName)
        #expect(done.destinationFilePath == harness.directory.appendingPathComponent(uniqueName).path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: done.destinationFilePath)) == payload)
        #expect(!FileManager.default.fileExists(atPath: escapedPath))
    }

    @Test("Concurrent same-name adds reserve distinct final and staging paths")
    func concurrentSameNameAddsDeCollide() async throws {
        let firstURL = URL(string: "https://one.example.com/file.bin")!
        let secondURL = URL(string: "https://two.example.com/file.bin")!
        let firstPayload = Data(repeating: 0x11, count: 80_000)
        let secondPayload = Data(repeating: 0x22, count: 90_000)
        let harness = try await Harness(resources: [firstURL: firstPayload, secondURL: secondPayload])
        defer { harness.cleanup() }

        async let firstAdd = harness.manager.add(DownloadRequest(
            url: firstURL,
            suggestedFileName: "shared.bin",
            destinationDirectoryPath: harness.directory.path
        ))
        async let secondAdd = harness.manager.add(DownloadRequest(
            url: secondURL,
            suggestedFileName: "shared.bin",
            destinationDirectoryPath: harness.directory.path
        ))
        let (first, second) = await (firstAdd, secondAdd)

        #expect(Set([first.fileName, second.fileName]) == ["shared.bin", "shared (2).bin"])
        #expect(first.destinationFilePath != second.destinationFilePath)
        #expect(first.partFilePath != second.partFilePath)

        let firstDone = try await harness.waitForCompletion(first.id)
        let secondDone = try await harness.waitForCompletion(second.id)
        #expect(try Data(contentsOf: URL(fileURLWithPath: firstDone.destinationFilePath)) == firstPayload)
        #expect(try Data(contentsOf: URL(fileURLWithPath: secondDone.destinationFilePath)) == secondPayload)
    }

    @Test("An existing destination directory is preserved and the download receives another name")
    func directorySentinelSurvivesDownload() async throws {
        let url = URL(string: "https://example.com/protected.bin")!
        let payload = Data(repeating: 0x5A, count: 20_000)
        let harness = try await Harness(resources: [url: payload])
        defer { harness.cleanup() }

        let protectedDirectory = harness.directory.appendingPathComponent("protected.bin")
        let sentinel = protectedDirectory.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: protectedDirectory, withIntermediateDirectories: true)
        try Data("do not delete".utf8).write(to: sentinel)

        let added = await harness.manager.add(DownloadRequest(
            url: url,
            suggestedFileName: "protected.bin",
            destinationDirectoryPath: harness.directory.path
        ))
        let done = try await harness.waitForCompletion(added.id)

        #expect(done.status == .completed)
        #expect(done.fileName == "protected (2).bin")
        #expect(try Data(contentsOf: sentinel) == Data("do not delete".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: done.destinationFilePath)) == payload)
    }

    @Test("Preparing a known-size part truncates stale trailing bytes")
    func prepareTruncatesOversizedPart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloakdrop-oversized-part-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let part = directory.appendingPathComponent("payload.bin.cdpart")
        try Data(repeating: 0xEE, count: 4_096).write(to: part)

        try SegmentedFileWriter.prepare(partPath: part.path, totalBytes: 128)

        let size = try #require(
            (try FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value
        )
        #expect(size == 128)
    }

    @Test("Finalization refuses to replace an existing file or directory")
    func finalizeNeverReplacesExistingDestination() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloakdrop-finalize-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let existingFile = directory.appendingPathComponent("existing.bin")
        let original = Data("original".utf8)
        try original.write(to: existingFile)
        let filePart = directory.appendingPathComponent("file.cdpart")
        try Data("replacement".utf8).write(to: filePart)

        #expect(throws: DownloadError.self) {
            try SegmentedFileWriter.finalize(partPath: filePart.path, destinationPath: existingFile.path)
        }
        #expect(try Data(contentsOf: existingFile) == original)
        #expect(FileManager.default.fileExists(atPath: filePart.path))

        let existingDirectory = directory.appendingPathComponent("existing-directory")
        let sentinel = existingDirectory.appendingPathComponent("sentinel.txt")
        try FileManager.default.createDirectory(at: existingDirectory, withIntermediateDirectories: true)
        try original.write(to: sentinel)
        let directoryPart = directory.appendingPathComponent("directory.cdpart")
        try Data("replacement".utf8).write(to: directoryPart)

        #expect(throws: DownloadError.self) {
            try SegmentedFileWriter.finalize(partPath: directoryPart.path, destinationPath: existingDirectory.path)
        }
        #expect(try Data(contentsOf: sentinel) == original)
        #expect(FileManager.default.fileExists(atPath: directoryPart.path))
    }

    @Test("A publication collision keeps the part resumable after auto-categorization")
    func categorizedCollisionCanResumeWithoutRetransfer() async throws {
        let url = URL(string: "https://example.com/resumable.bin")!
        let payload = Data(repeating: 0x6B, count: 64_000)
        let harness = try await Harness(resources: [url: payload])
        defer { harness.cleanup() }

        var settings = await harness.manager.currentSettings()
        settings.autoCategorize = true
        await harness.manager.updateSettings(settings)
        let added = await harness.manager.add(DownloadRequest(
            url: url, suggestedFileName: "resumable.bin",
            destinationDirectoryPath: harness.directory.path, startImmediately: false
        ))

        let categoryDirectory = harness.directory.appendingPathComponent(added.category.displayName)
        try FileManager.default.createDirectory(at: categoryDirectory, withIntermediateDirectories: true)
        let collision = categoryDirectory.appendingPathComponent(added.fileName)
        let sentinel = Data("existing".utf8)
        try sentinel.write(to: collision)
        await harness.manager.resume(id: added.id)

        let deadline = ContinuousClock().now + .seconds(10)
        var failed: Download?
        while ContinuousClock().now < deadline {
            if let candidate = await harness.manager.snapshot().downloads.first(where: { $0.id == added.id }),
               case .failed = candidate.status {
                failed = candidate
                break
            }
            try await Task.sleep(for: .milliseconds(15))
        }
        let blocked = try #require(failed)
        #expect(blocked.destinationDirectoryPath == harness.directory.path)
        #expect(FileManager.default.fileExists(atPath: blocked.partFilePath))
        #expect(try Data(contentsOf: collision) == sentinel)

        let streamsAfterFailure = harness.mock.streamCount
        try FileManager.default.removeItem(at: collision)
        await harness.manager.resume(id: added.id)
        let done = try await harness.waitForCompletion(added.id)
        #expect(done.status == .completed)
        #expect(harness.mock.streamCount == streamsAfterFailure)
        #expect(try Data(contentsOf: URL(fileURLWithPath: done.destinationFilePath)) == payload)
    }
}
