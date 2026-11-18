import Foundation
import Testing
import CryptoKit
@testable import DownloadModels
@testable import DownloadPersistence
@testable import DownloadEngine

struct DownloadWorkflowHarness {
    let directory: URL
    let store: GRDBDownloadStore
    let mock = MockHTTPClient()
    let manager: DownloadManager
    let payload = Data((0..<128_000).map { UInt8($0 % 251) })
    let source = URL(string: "https://example.com/file.bin?token=old")!
    let replacement = URL(string: "https://example.com/file.bin?token=new")!

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("download-workflows-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try GRDBDownloadStore(path: directory.appendingPathComponent("catalog.sqlite").path)
        manager = DownloadManager(store: store, httpClient: mock, networkMonitor: AlwaysReachableMonitor())
        try await manager.start()
        var settings = await manager.currentSettings()
        settings.autoDiscoverChecksums = false
        settings.minimumSegmentSizeBytes = 16_000
        await manager.updateSettings(settings)
    }

    func partial() async throws -> Download {
        let added = await manager.add(DownloadRequest(
            url: source, suggestedFileName: "payload.bin", destinationDirectoryPath: directory.path,
            startImmediately: false
        ))
        var download = added
        download.totalBytes = Int64(payload.count)
        download.supportsResume = true
        download.etag = "\"version-one\""
        download.validatorURL = source
        download.segments = [DownloadSegment(id: 0, start: 0, end: Int64(payload.count - 1), downloadedBytes: 32_000)]
        try SegmentedFileWriter.prepare(partPath: download.partFilePath, totalBytes: download.totalBytes)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: download.partFilePath))
        try handle.write(contentsOf: payload.prefix(32_000))
        try handle.close()
        await manager.seedWorkflowRecord(download)
        return download
    }

    func waitFor(_ id: UUID, manager other: DownloadManager? = nil,
                 predicate: (Download) -> Bool = { $0.status == .completed }) async throws -> Download {
        let target = other ?? manager
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let item = await target.snapshot().downloads.first(where: { $0.id == id }), predicate(item) { return item }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WorkflowTimeout()
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

struct WorkflowTimeout: Error {}

extension DownloadManager {
    func seedWorkflowRecord(_ download: Download) async {
        downloads[download.id] = download
        await persistOrderedAndWait(download)
    }
}
