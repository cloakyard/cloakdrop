import Foundation
import Network

/// A tiny loopback FTP server for integration tests: enough of RFC 959 to exercise the real
/// `FTPClient` — greeting, USER/PASS, TYPE I, SIZE, EPSV, REST, RETR, QUIT — over passive mode on
/// loopback. Serves a fixed payload and can optionally reject `REST` so fallback can be tested.
final class LoopbackFTPServer: @unchecked Sendable {
    private let control: NWListener
    private let payload: Data
    private let supportsREST: Bool
    private let stallsDuringTransfer: Bool
    private let supportsEPSV: Bool
    private let queue = DispatchQueue(label: "cloakdrop.loopback.ftp")

    private(set) var port: UInt16 = 0

    init(payload: Data, supportsREST: Bool = true, stallsDuringTransfer: Bool = false, supportsEPSV: Bool = true) throws {
        self.payload = payload
        self.supportsREST = supportsREST
        self.stallsDuringTransfer = stallsDuringTransfer
        self.supportsEPSV = supportsEPSV
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        self.control = try NWListener(using: params)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            control.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = self?.control.port?.rawValue ?? 0
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                default: break
                }
            }
            control.newConnectionHandler = { [weak self] connection in
                self?.handleControl(connection)
            }
            control.start(queue: queue)
        }
    }

    func stop() { control.cancel() }

    var baseURL: URL { URL(string: "ftp://127.0.0.1:\(port)/file.bin")! }

    // MARK: Control session

    // Serialized on the server's queue; safe to pass across the NWConnection handler closures.
    private final class Session: @unchecked Sendable {
        var restOffset: Int = 0
        var dataListener: NWListener?
        var dataPort: UInt16 = 0
        var pendingData: NWConnection?
    }

    private func handleControl(_ connection: NWConnection) {
        connection.start(queue: queue)
        let session = Session()
        send(connection, "220 Loopback FTP ready\r\n")
        readCommand(connection, session: session, buffer: Data())
    }

    private func readCommand(_ connection: NWConnection, session: Session, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            while let range = accumulated.range(of: Data("\r\n".utf8)) {
                let line = String(decoding: accumulated[..<range.lowerBound], as: UTF8.self)
                accumulated.removeSubrange(..<range.upperBound)
                self.handle(line: line, connection: connection, session: session)
            }
            if error == nil && !isComplete {
                self.readCommand(connection, session: session, buffer: accumulated)
            }
        }
    }

    private func handle(line: String, connection: NWConnection, session: Session) {
        let parts = line.split(separator: " ", maxSplits: 1)
        let verb = parts.first.map { $0.uppercased() } ?? ""
        let arg = parts.count > 1 ? String(parts[1]) : ""

        switch verb {
        case "USER": send(connection, "331 Need password\r\n")
        case "PASS": send(connection, "230 Logged in\r\n")
        case "TYPE": send(connection, "200 Type set\r\n")
        case "SIZE": send(connection, "213 \(payload.count)\r\n")
        case "REST":
            if supportsREST {
                session.restOffset = Int(arg) ?? 0
                send(connection, "350 Restarting\r\n")
            } else {
                send(connection, "502 REST not supported\r\n")
            }
        case "EPSV":
            if supportsEPSV { openPassive(connection, session: session) }
            else { send(connection, "502 EPSV unsupported\r\n") }
        case "PASV": openPassivePASV(connection, session: session)
        case "RETR": retrieve(connection, session: session)
        case "QUIT": send(connection, "221 Bye\r\n"); connection.cancel()
        default: send(connection, "200 OK\r\n")
        }
    }

    private func makeDataListener(_ session: Session) -> NWListener? {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params) else { return nil }
        session.dataListener = listener
        listener.newConnectionHandler = { connection in connection.start(queue: self.queue) ; session.pendingData = connection }
        listener.start(queue: queue)
        return listener
    }

    private func openPassive(_ connection: NWConnection, session: Session) {
        guard let listener = makeDataListener(session) else { send(connection, "500 No data\r\n"); return }
        waitForPort(listener) { [weak self] port in
            session.dataPort = port
            self?.send(connection, "229 Entering Extended Passive Mode (|||\(port)|)\r\n")
        }
    }

    private func openPassivePASV(_ connection: NWConnection, session: Session) {
        guard let listener = makeDataListener(session) else { send(connection, "500 No data\r\n"); return }
        waitForPort(listener) { [weak self] port in
            session.dataPort = port
            let p1 = port / 256, p2 = port % 256
            // A mismatched private address models a server behind NAT. The client must use the
            // control host, regardless of the address a PASV response advertises.
            self?.send(connection, "227 Entering Passive Mode (192,0,2,1,\(p1),\(p2))\r\n")
        }
    }

    private func waitForPort(_ listener: NWListener, _ completion: @escaping @Sendable (UInt16) -> Void) {
        listener.stateUpdateHandler = { state in
            if case .ready = state { completion(listener.port?.rawValue ?? 0) }
        }
    }

    private func retrieve(_ connection: NWConnection, session: Session) {
        send(connection, "150 Opening data connection\r\n")
        guard !stallsDuringTransfer else { return }
        // The data connection may not have been accepted yet; poll briefly.
        deliverWhenReady(connection, session: session, attempts: 0)
    }

    private func deliverWhenReady(_ connection: NWConnection, session: Session, attempts: Int) {
        if let data = session.pendingData {
            let body = payload.subdata(in: min(session.restOffset, payload.count)..<payload.count)
            data.send(content: body, completion: .contentProcessed { _ in
                data.cancel()
                self.send(connection, "226 Transfer complete\r\n")
            })
        } else if attempts < 200 {
            queue.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.deliverWhenReady(connection, session: session, attempts: attempts + 1)
            }
        } else {
            send(connection, "425 No data connection\r\n")
        }
    }

    private func send(_ connection: NWConnection, _ text: String) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }
}
