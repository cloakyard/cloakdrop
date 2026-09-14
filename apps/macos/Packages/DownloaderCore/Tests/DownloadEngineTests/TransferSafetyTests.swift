import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadPersistence
@testable import DownloadEngine

@Suite("Transfer response integrity")
struct TransferSafetyTests {
    @Test("Extreme persisted segment IDs and connection caps remain safe during retries and work stealing",
          arguments: [2, Int.max])
    func extremePersistedIDCanSplit(maximumSegments: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resume-ids-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = Data((0..<200_000).map { UInt8($0 % 251) })
        let url = URL(string: "https://example.com/body.bin")!
        let client = MockHTTPClient(resources: [url: .init(data: expected)], pendingDrops: 2, dropAfterBytes: 4_096)
        client.chunkSize = 4_096
        client.slowFromOffset = 16_384
        client.slowChunkDelay = .milliseconds(2)
        let store = try GRDBDownloadStore.inMemory()
        try await store.bootstrap()
        var download = Download(url: url, fileName: "body.bin", destinationDirectoryPath: directory.path,
                                totalBytes: Int64(expected.count), supportsResume: true, segments: [
                                    DownloadSegment(id: .max, start: 0, end: 16_383),
                                    DownloadSegment(id: 1, start: 16_384, end: Int64(expected.count - 1))
                                ], requestedSegmentCount: 2)
        download.status = .paused
        try await store.save(download)
        let restored = try #require(await store.download(id: download.id))
        let settings = EngineSettings(defaultSegmentCount: 2, maxSegmentCount: maximumSegments, minimumSegmentSizeBytes: 8_192,
                                      autoDiscoverChecksums: false, assessSignatures: false, applyQuarantine: false,
                                      generateProvenanceReceipts: false)
        let task = DownloadTask(download: restored, httpClient: client, store: store,
                                globalLimiter: BandwidthLimiter(bytesPerSecond: nil), settings: settings, emit: { _ in })
        let result = await task.run()
        #expect(result.status == .completed)
        #expect(result.segments.count > 2)
        #expect(try Data(contentsOf: URL(fileURLWithPath: result.destinationFilePath)) == expected)
    }

    @Test("Unsafe persisted segment layouts restart instead of publishing stale staging bytes",
          arguments: ["gap", "overlap", "duplicate IDs", "short coverage", "excess coverage", "unknown size", "whole stream"])
    func invalidPersistedLayoutRestarts(kind: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resume-layout-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = Data("correct!".utf8)
        let url = URL(string: "https://example.com/body.bin")!
        let client = MockHTTPClient(resources: [url: .init(data: expected)])
        let store = try GRDBDownloadStore.inMemory()
        try await store.bootstrap()
        var download = Download(url: url, fileName: "body.bin", destinationDirectoryPath: directory.path)
        download.status = .paused
        download.totalBytes = 8
        download.supportsResume = true
        download.segments = [
            DownloadSegment(id: 0, start: 0, end: 3, downloadedBytes: 4),
            DownloadSegment(id: 1, start: 4, end: 7, downloadedBytes: 4)
        ]
        switch kind {
        case "gap": download.segments[0] = DownloadSegment(id: 0, start: 0, end: 2, downloadedBytes: 3)
        case "overlap": download.segments[0] = DownloadSegment(id: 0, start: 0, end: 4, downloadedBytes: 5)
        case "duplicate IDs": download.segments[1] = DownloadSegment(id: 0, start: 4, end: 7, downloadedBytes: 4)
        case "short coverage": download.segments.removeLast()
        case "excess coverage": download.segments[1] = DownloadSegment(id: 1, start: 4, end: 8, downloadedBytes: 5)
        case "unknown size": download.totalBytes = nil
        default: download.supportsResume = false
        }
        try Data(repeating: 120, count: 9).write(to: URL(fileURLWithPath: download.partFilePath))
        try await store.save(download)
        let restored = try #require(await store.download(id: download.id))
        let settings = EngineSettings(autoDiscoverChecksums: false, assessSignatures: false,
                                      applyQuarantine: false, generateProvenanceReceipts: false)
        let task = DownloadTask(download: restored, httpClient: client, store: store,
                                globalLimiter: BandwidthLimiter(bytesPerSecond: nil), settings: settings, emit: { _ in })
        let result = await task.run()
        #expect(result.status == .completed)
        #expect(result.downloadedBytes == 8)
        #expect(try Data(contentsOf: URL(fileURLWithPath: result.destinationFilePath)) == expected)
    }

    @Test("A completed range with excess trailing bytes restarts coherently even when mirrors exist")
    func oversizedRangeCannotEscapeThroughMirrorCompletion() async throws {
        let client = OversizedRangeClient()
        let result = try await run(client, mirrors: [URL(string: "https://mirror.example.com/body.bin")!])
        defer { try? FileManager.default.removeItem(at: result.directory) }
        #expect(result.download.status == .completed)
        #expect(await client.usedWholeBodyFallback)
        #expect(try Data(contentsOf: URL(fileURLWithPath: result.download.destinationFilePath)) == Data("good".utf8))
    }

    @Test("An unknown-size retry discards the old body's suffix")
    func unknownSizeRetryTruncatesPreviousBody() async throws {
        let replacement = Data("new".utf8)
        let client = ScriptedBodyClient(total: nil, bodies: [
            .init(data: Data("old longer partial body".utf8), failure: .networkLost),
            .init(data: replacement)
        ])
        let result = try await run(client)
        defer { try? FileManager.default.removeItem(at: result.directory) }
        #expect(result.download.status == .completed)
        #expect(result.download.downloadedBytes == Int64(replacement.count))
        #expect(try Data(contentsOf: URL(fileURLWithPath: result.download.destinationFilePath)) == replacement)
    }

    @Test("A full body larger than its advertised size cannot publish a truncated file",
          arguments: [false, true])
    func oversizedBodyIsRejected(splitChunks: Bool) async throws {
        let client = ScriptedBodyClient(total: 4, bodies: [
            .init(data: Data("excess".utf8), chunkSize: splitChunks ? 4 : 6)
        ])
        let result = try await run(client, retryFailure: true)
        defer { try? FileManager.default.removeItem(at: result.directory) }
        if case .failed = result.download.status {} else { Issue.record("Expected oversized response to fail") }
        #expect(!FileManager.default.fileExists(atPath: result.download.destinationFilePath))
    }

    @Test("An unsolicited partial response cannot complete a whole-file request")
    func unsolicitedPartialBodyIsRejected() async throws {
        let client = ScriptedBodyClient(total: nil, status: 206, bodies: [.init(data: Data("partial".utf8))])
        let result = try await run(client)
        defer { try? FileManager.default.removeItem(at: result.directory) }
        if case .failed = result.download.status {} else { Issue.record("Expected unsolicited partial response to fail") }
        #expect(!FileManager.default.fileExists(atPath: result.download.destinationFilePath))
    }

    private func run(
        _ client: any HTTPClient, retryFailure: Bool = false, mirrors: [URL]? = nil
    ) async throws -> (download: Download, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-integrity-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try GRDBDownloadStore.inMemory()
        try await store.bootstrap()
        let download = Download(url: URL(string: "https://example.com/body.bin")!, mirrors: mirrors, fileName: "body.bin",
                                destinationDirectoryPath: directory.path)
        let settings = EngineSettings(
            maxRetryAttempts: 1, retryBaseDelaySeconds: 0, retryMaxDelaySeconds: 0,
            autoDiscoverChecksums: false, assessSignatures: false, applyQuarantine: false,
            generateProvenanceReceipts: false
        )
        let task = DownloadTask(download: download, httpClient: client, store: store,
                                globalLimiter: BandwidthLimiter(bytesPerSecond: nil), settings: settings,
                                emit: { _ in })
        let first = await task.run()
        guard retryFailure else { return (first, directory) }
        if case .failed = first.status {} else { Issue.record("First attempt should fail") }
        let retry = DownloadTask(download: first, httpClient: client, store: store,
                                 globalLimiter: BandwidthLimiter(bytesPerSecond: nil), settings: settings,
                                 emit: { _ in })
        return (await retry.run(), directory)
    }
}

private actor OversizedRangeClient: HTTPClient {
    private(set) var usedWholeBodyFallback = false

    func probe(_ request: HTTPDownloadRequest) async throws -> HTTPResponseHead {
        HTTPResponseHead(statusCode: 206, totalBytes: 4, acceptsRanges: true,
                         suggestedFilename: nil, etag: nil, contentRange: 0...0)
    }

    func stream(_ request: HTTPDownloadRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<Data, Error>) {
        let ranged = request.byteRange != nil
        let head = HTTPResponseHead(statusCode: ranged ? 206 : 200, totalBytes: 4, acceptsRanges: true,
                                    suggestedFilename: nil, etag: nil, contentRange: request.byteRange)
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        if ranged {
            continuation.yield(Data("evil".utf8))
            continuation.yield(Data("!".utf8))
        } else {
            usedWholeBodyFallback = true
            continuation.yield(Data("good".utf8))
        }
        continuation.finish()
        return (head, stream)
    }
}

/// Deliberately inconsistent responses that a well-behaved mock server would never construct.
private actor ScriptedBodyClient: HTTPClient {
    struct Body: Sendable {
        var data: Data
        var failure: DownloadError?
        var chunkSize: Int = 1_024
    }
    let total: Int64?
    let status: Int
    var bodies: [Body]

    init(total: Int64?, status: Int = 200, bodies: [Body]) {
        self.total = total
        self.status = status
        self.bodies = bodies
    }

    func probe(_ request: HTTPDownloadRequest) async throws -> HTTPResponseHead {
        HTTPResponseHead(statusCode: 200, totalBytes: total, acceptsRanges: false,
                         suggestedFilename: nil, etag: nil)
    }

    func stream(_ request: HTTPDownloadRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<Data, Error>) {
        let body = bodies.count > 1 ? bodies.removeFirst() : bodies[0]
        let head = HTTPResponseHead(statusCode: status, totalBytes: total, acceptsRanges: false,
                                    suggestedFilename: nil, etag: nil)
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        for offset in stride(from: 0, to: body.data.count, by: body.chunkSize) {
            continuation.yield(body.data.subdata(in: offset..<min(offset + body.chunkSize, body.data.count)))
        }
        if let failure = body.failure { continuation.finish(throwing: failure) } else { continuation.finish() }
        return (head, stream)
    }
}
