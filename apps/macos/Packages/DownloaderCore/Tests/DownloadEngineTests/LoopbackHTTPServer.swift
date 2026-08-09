import Foundation
import Network

/// A tiny loopback HTTP/1.1 server for integration tests. Serves a fixed payload, honors
/// `Range` requests with `206 Partial Content` + `Content-Range`, and advertises
/// `Accept-Ranges: bytes` — enough to exercise the real `URLSessionHTTPClient` path.
final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let payload: Data
    private let queue = DispatchQueue(label: "cloakdrop.loopback.server")
    let acceptsRanges: Bool
    private let stallsBeforeResponse: Bool

    private(set) var port: UInt16 = 0

    init(payload: Data, acceptsRanges: Bool = true, stallsBeforeResponse: Bool = false) throws {
        self.payload = payload
        self.acceptsRanges = acceptsRanges
        self.stallsBeforeResponse = stallsBeforeResponse
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: params)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = self?.listener.port?.rawValue ?? 0
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if let headerEnd = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: accumulated[..<headerEnd.lowerBound], as: UTF8.self)
                self.respond(connection, requestHeader: header)
            } else if error == nil && !isComplete {
                self.receiveRequest(connection, buffer: accumulated)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, requestHeader: String) {
        if stallsBeforeResponse { return }
        let lines = requestHeader.split(separator: "\r\n", omittingEmptySubsequences: false)
        var rangeHeader: String?
        for line in lines where line.lowercased().hasPrefix("range:") {
            rangeHeader = String(line.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces)
        }

        let total = payload.count
        var status = "200 OK"
        var bodyStart = 0
        var bodyEnd = total - 1
        var extraHeaders = ""

        if acceptsRanges {
            extraHeaders += "Accept-Ranges: bytes\r\n"
        }
        if acceptsRanges, rangeHeader != nil, total == 0 {
            status = "416 Range Not Satisfiable"
            extraHeaders += "Content-Range: bytes */0\r\n"
        } else if acceptsRanges, let rangeHeader, let parsed = Self.parseRange(rangeHeader, total: total) {
            status = "206 Partial Content"
            bodyStart = parsed.lowerBound
            bodyEnd = parsed.upperBound
            extraHeaders += "Content-Range: bytes \(bodyStart)-\(bodyEnd)/\(total)\r\n"
        }

        let body = total == 0 ? Data() : payload.subdata(in: bodyStart..<(bodyEnd + 1))
        var response = "HTTP/1.1 \(status)\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += extraHeaders
        response += "Connection: close\r\n\r\n"

        var out = Data(response.utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func parseRange(_ value: String, total: Int) -> ClosedRange<Int>? {
        guard value.hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let lowerString = parts.first, let lower = Int(lowerString) else { return nil }
        let upper: Int
        if parts.count == 2, let u = Int(parts[1]) { upper = u } else { upper = total - 1 }
        guard lower <= upper, upper < total else { return nil }
        return lower...upper
    }
}
