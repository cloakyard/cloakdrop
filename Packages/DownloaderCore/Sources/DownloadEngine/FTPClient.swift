import Foundation
import Network
import DownloadModels

/// A native FTP / FTPS client that plugs into the engine's `HTTPClient` seam, so FTP downloads flow
/// through the exact same segmented-transfer, resume, throttle, and persistence machinery as HTTP —
/// no bundled library, just `Network.framework`.
///
/// Supports plain `ftp://` and **explicit** `ftps://` (RFC 4217 `AUTH TLS`, the common flavor), using
/// passive mode (`EPSV`, falling back to `PASV`) so it works from behind NAT without inbound ports.
/// Resume is real: `REST <offset>` before `RETR` starts the byte stream at the segment's offset, which
/// is exactly what the engine's per-segment resume needs. The wire-protocol parsing lives in the pure
/// `FTPProtocol`; this type is the I/O around it.
public actor FTPClient: HTTPClient {
    private let queue = DispatchQueue(label: "com.cloakyard.cloakdrop.ftp")

    public init() {}

    // MARK: HTTPClient

    public func probe(_ request: HTTPDownloadRequest) async throws -> HTTPResponseHead {
        let control = try await openControlConnection(for: request)
        defer { control.cancel() }

        let size = try? await control.size(path: FTPProtocol.path(for: request.url))
        return HTTPResponseHead(
            statusCode: 200,
            totalBytes: size,
            acceptsRanges: true,        // FTP servers that speak REST support resume; we probe REST lazily
            suggestedFilename: request.url.lastPathComponent.isEmpty ? nil : request.url.lastPathComponent,
            etag: nil,
            finalURL: request.url,
            mimeType: nil
        )
    }

    public func stream(_ request: HTTPDownloadRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<Data, Error>) {
        let control = try await openControlConnection(for: request)
        let path = FTPProtocol.path(for: request.url)
        let size = try? await control.size(path: path)

        let offset = request.byteRange?.lowerBound ?? 0
        // Open the passive data connection, then issue RETR (optionally after REST for resume).
        let data = try await control.openPassiveData(tls: request.url.scheme?.lowercased() == "ftps")
        if offset > 0 { try await control.restart(at: offset) }
        try await control.retrieve(path: path)

        let head = HTTPResponseHead(
            statusCode: 200,
            totalBytes: size,
            acceptsRanges: true,
            suggestedFilename: request.url.lastPathComponent.isEmpty ? nil : request.url.lastPathComponent,
            etag: nil,
            finalURL: request.url,
            mimeType: nil
        )

        // Bound the stream to the segment's byte count when the caller asked for a range: FTP's REST
        // only sets a start, so we stop reading once we've delivered `end - start + 1` bytes.
        let limit: Int64? = request.byteRange.map { $0.upperBound - $0.lowerBound + 1 }
        let stream = data.bodyStream(byteLimit: limit) {
            // On completion/cancellation, read the transfer-complete reply and close the control link.
            Task { await control.finishTransfer() }
        }
        return (head, stream)
    }

    // MARK: Control connection

    private func openControlConnection(for request: HTTPDownloadRequest) async throws -> FTPControlConnection {
        let scheme = request.url.scheme?.lowercased() ?? "ftp"
        let secure = scheme == "ftps"
        // ftps implicit-TLS defaults to 990; plain FTP to 21.
        let port = UInt16(request.url.port ?? (secure ? 990 : 21))
        guard let host = request.url.host else { throw DownloadError.underlying(reason: "FTP URL has no host.") }

        let control = FTPControlConnection(host: host, port: port, secure: secure, queue: queue)
        try await control.connect()
        try await control.login(user: request.username ?? "anonymous",
                                password: request.password ?? "anonymous@cloakdrop")
        try await control.binaryMode()
        if secure { try await control.protectDataChannel() }
        return control
    }
}
