import Foundation
import Testing
@testable import DownloadEngine

@Suite("FTP client (loopback server)")
struct FTPClientIntegrationTests {
    private func collect(_ stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var out = Data()
        for try await chunk in stream { out.append(chunk) }
        return out
    }

    @Test("Probes size and downloads the whole file over FTP")
    func fullDownload() async throws {
        let payload = Data((0..<50_000).map { UInt8($0 % 251) })
        let server = try LoopbackFTPServer(payload: payload)
        try await server.start()
        defer { server.stop() }

        let client = FTPClient()
        let request = HTTPDownloadRequest(url: server.baseURL)

        let head = try await client.probe(request)
        #expect(head.totalBytes == Int64(payload.count))
        #expect(head.acceptsRanges)

        let (_, stream) = try await client.stream(request)
        let body = try await collect(stream)
        #expect(body == payload)
    }

    @Test("Resumes from a byte offset via REST (what per-segment resume needs)")
    func restResume() async throws {
        let payload = Data((0..<40_000).map { UInt8(($0 * 7) % 251) })
        let server = try LoopbackFTPServer(payload: payload)
        try await server.start()
        defer { server.stop() }

        let client = FTPClient()
        let offset: Int64 = 10_000
        let end: Int64 = 19_999
        let request = HTTPDownloadRequest(url: server.baseURL, byteRange: offset...end)

        let (_, stream) = try await client.stream(request)
        let body = try await collect(stream)

        // The ranged fetch must return exactly [offset, end] of the payload.
        #expect(body.count == Int(end - offset + 1))
        #expect(body == payload.subdata(in: Int(offset)..<Int(end + 1)))
    }
}
