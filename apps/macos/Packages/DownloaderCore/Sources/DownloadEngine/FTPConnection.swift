import Foundation
import Network
import DownloadModels

/// The FTP control channel: an actor around one `NWConnection` that sends commands and frames replies
/// through the pure `FTPProtocol`. Serializing on the actor guarantees one command/response exchange
/// at a time, which is exactly FTP's model.
///
/// `ftps://` is treated as **implicit** TLS (the connection is TLS from its first byte) because
/// `NWConnection` cannot upgrade an already-established socket — so explicit `AUTH TLS` STARTTLS-style
/// upgrade isn't expressible here. Implicit FTPS is the flavor the `ftps://` scheme cleanly denotes.
actor FTPControlConnection {
    private let connection: NWConnection
    private let host: String
    private let queue: DispatchQueue
    private let secure: Bool
    private let opTimeout: Duration
    private var buffer = Data()
    /// A well-behaved server frames a reply in far less than this; a larger unframed buffer means a
    /// hostile/broken peer, so we bail rather than grow memory unbounded.
    private static let maxReplyBytes = 64 * 1024

    init(host: String, port: UInt16, secure: Bool, queue: DispatchQueue, timeout: Duration = .seconds(30)) {
        self.host = host
        self.queue = queue
        self.secure = secure
        self.opTimeout = timeout
        let params: NWParameters = secure ? .tls : .tcp
        self.connection = NWConnection(host: NWEndpoint.Host(host),
                                       port: NWEndpoint.Port(rawValue: port) ?? (secure ? 990 : 21),
                                       using: params)
    }

    // MARK: Lifecycle

    func connect() async throws {
        try await waitUntilReady()
        let greeting = try await readReply()
        guard greeting.code == 220 else { throw FTPError.unexpected(greeting) }
    }

    func login(user: String, password: String) async throws {
        let userReply = try await send("USER \(user)")
        // 230 = logged in without a password; 331 = need a password next.
        if userReply.code == 230 { return }
        guard userReply.isPositiveIntermediate else { throw FTPError.unexpected(userReply) }
        let passReply = try await send("PASS \(password)")
        guard passReply.isPositiveCompletion else { throw FTPError.auth(passReply) }
    }

    func binaryMode() async throws {
        let reply = try await send("TYPE I")
        guard reply.isPositiveCompletion else { throw FTPError.unexpected(reply) }
    }

    /// PBSZ 0 + PROT P so the data channel is TLS-protected too (FTPS). Best-effort: some implicit
    /// servers reject these, in which case the data connection still inherits TLS from the scheme.
    func protectDataChannel() async throws {
        _ = try? await send("PBSZ 0")
        _ = try? await send("PROT P")
    }

    func size(path: String) async throws -> Int64 {
        let reply = try await send("SIZE \(path)")
        guard reply.code == 213, let size = FTPProtocol.parseSize(reply.text) else { throw FTPError.unexpected(reply) }
        return size
    }

    func restart(at offset: Int64) async throws {
        let reply = try await send("REST \(offset)")
        guard reply.code == 350 else { throw FTPError.unexpected(reply) }
    }

    /// Open a passive-mode data connection: try `EPSV` (RFC 2428, IPv6-friendly) then fall back to
    /// `PASV`. Returns a *ready* data connection.
    func openPassiveData(tls: Bool) async throws -> FTPDataConnection {
        if let epsv = try? await send("EPSV"), epsv.code == 229,
           let port = FTPProtocol.parseExtendedPassivePort(epsv.text) {
            return try await FTPDataConnection.open(host: host, port: UInt16(port), tls: tls, queue: queue)
        }
        let pasv = try await send("PASV")
        guard pasv.code == 227, let address = FTPProtocol.parsePassiveAddress(pasv.text) else {
            throw FTPError.unexpected(pasv)
        }
        return try await FTPDataConnection.open(host: address.host, port: UInt16(address.port), tls: tls, queue: queue)
    }

    /// Issue RETR; the server answers with a 1xx preliminary (150/125) once the data connection is
    /// about to stream. The 2xx completion is read later by `finishTransfer`.
    func retrieve(path: String) async throws {
        let reply = try await send("RETR \(path)")
        guard reply.isPositivePreliminary else { throw FTPError.unexpected(reply) }
    }

    /// Drain the transfer-complete (226) reply and close the control link. Best-effort — the bytes
    /// are already delivered by the time this runs.
    func finishTransfer() async {
        _ = try? await readReply()
        _ = try? await send("QUIT")
        connection.cancel()
    }

    nonisolated func cancel() { connection.cancel() }

    // MARK: Command / reply plumbing

    private func send(_ command: String) async throws -> FTPProtocol.Reply {
        try await write(Data((command + "\r\n").utf8))
        return try await readReply()
    }

    private func readReply() async throws -> FTPProtocol.Reply {
        while true {
            if let text = String(data: buffer, encoding: .utf8),
               let (reply, remainder) = FTPProtocol.parseReply(from: text) {
                buffer = Data(remainder.utf8)
                if reply.isNegative { throw FTPError.unexpected(reply) }
                return reply
            }
            // A peer that never frames a valid reply must not grow the buffer forever.
            guard buffer.count < Self.maxReplyBytes else { throw FTPError.protocolError }
            buffer.append(try await receive())
        }
    }

    // MARK: NWConnection bridging

    /// Run `body` with an idle timeout and cooperative cancellation: if it doesn't finish within
    /// `opTimeout`, or the surrounding `Task` is cancelled (pause/cancel), the connection is torn down —
    /// which resumes any pending `NWConnection` callback via its error/`.cancelled` path. Without this,
    /// a `.waiting` (unreachable/refused) connection or a stalled read would hang forever.
    private func withTimeout<T>(_ body: () async throws -> T) async throws -> T {
        let connection = self.connection
        let timeoutTask = Task { [connection, opTimeout] in
            try? await Task.sleep(for: opTimeout)
            guard !Task.isCancelled else { return }   // completed in time — don't tear down the socket.
            connection.cancel()
        }
        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler {
            try await body()
        } onCancel: {
            connection.cancel()
        }
    }

    private func waitUntilReady() async throws {
        let box = ContinuationBox()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: box.resume(.success(()))
            case .failed(let error): box.resume(.failure(error))
            case .cancelled: box.resume(.failure(FTPError.connectionClosed))
            // `.waiting` (host unreachable / connection refused) is left to the timeout to tear down,
            // so a transient wait can still recover to `.ready` while a persistent one can't hang.
            default: break
            }
        }
        connection.start(queue: queue)
        try await withTimeout { try await box.value() }
        connection.stateUpdateHandler = nil
    }

    private func write(_ data: Data) async throws {
        let box = ContinuationBox()
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { box.resume(.failure(error)) } else { box.resume(.success(())) }
        })
        try await withTimeout { try await box.value() }
    }

    private func receive() async throws -> Data {
        try await withTimeout {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let error { continuation.resume(throwing: error); return }
                    if let data, !data.isEmpty { continuation.resume(returning: data); return }
                    if isComplete { continuation.resume(throwing: FTPError.connectionClosed); return }
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}

/// The FTP data channel: a `NWConnection` that streams the file body into an `AsyncThrowingStream`
/// the engine consumes exactly like an HTTP body.
actor FTPDataConnection {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let opTimeout: Duration

    private init(connection: NWConnection, queue: DispatchQueue, timeout: Duration) {
        self.connection = connection
        self.queue = queue
        self.opTimeout = timeout
    }

    static func open(host: String, port: UInt16, tls: Bool, queue: DispatchQueue,
                     timeout: Duration = .seconds(30)) async throws -> FTPDataConnection {
        let params: NWParameters = tls ? .tls : .tcp
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: NWEndpoint.Port(rawValue: port) ?? .any,
                                      using: params)
        let data = FTPDataConnection(connection: connection, queue: queue, timeout: timeout)
        do {
            try await data.waitUntilReady()
        } catch {
            connection.cancel()   // a passive data channel that never came up must not leak.
            throw error
        }
        return data
    }

    nonisolated func cancel() { connection.cancel() }

    private func waitUntilReady() async throws {
        let box = ContinuationBox()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: box.resume(.success(()))
            case .failed(let error): box.resume(.failure(error))
            case .cancelled: box.resume(.failure(FTPError.connectionClosed))
            default: break   // `.waiting` is torn down by the timeout below.
            }
        }
        connection.start(queue: queue)
        let connection = self.connection
        let timeoutTask = Task { [connection, opTimeout] in
            try? await Task.sleep(for: opTimeout)
            guard !Task.isCancelled else { return }
            connection.cancel()
        }
        defer { timeoutTask.cancel() }
        try await withTaskCancellationHandler {
            try await box.value()
        } onCancel: {
            connection.cancel()
        }
        connection.stateUpdateHandler = nil
    }

    /// Stream the body, stopping at EOF or after `byteLimit` bytes (for a ranged segment). `onFinish`
    /// runs once the stream ends or is cancelled, so the control connection can read the 226 and close.
    nonisolated func bodyStream(byteLimit: Int64?, onFinish: @escaping @Sendable () -> Void) -> AsyncThrowingStream<Data, Error> {
        let connection = self.connection
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(4)
        )
        // FTP has no per-message framing, so a pump re-arms `receive` until EOF or the byte limit.
        // It pauses when the four-chunk stream buffer fills, providing bounded backpressure.
        let pump = FTPBodyStreamPump(
            connection: connection,
            byteLimit: byteLimit,
            continuation: continuation
        )
        continuation.onTermination = { [weak pump] _ in
            connection.cancel()
            pump?.stop()
            onFinish()
        }
        // The connection was already started (and awaited ready) in `open` — just begin reading.
        pump.start()
        return stream
    }
}

/// Demand-aware bridge from `NWConnection.receive` into the bounded async body stream. Each receive
/// callback owns the pump until it hands off to the next receive (or a retry task), avoiding stored
/// self-referential closures while keeping the pump alive for the transfer's duration.
private final class FTPBodyStreamPump: @unchecked Sendable {
    private let connection: NWConnection
    private let byteLimit: Int64?
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let delivered = DeliveredCounter()
    private let stateLock = NSLock()
    private var stopped = false

    init(
        connection: NWConnection,
        byteLimit: Int64?,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) {
        self.connection = connection
        self.byteLimit = byteLimit
        self.continuation = continuation
    }

    func start() {
        receiveNext()
    }

    func stop() {
        stateLock.withLock { stopped = true }
    }

    private var isStopped: Bool {
        stateLock.withLock { stopped }
    }

    private func receiveNext() {
        guard !isStopped else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, isComplete, error in
            handleReceive(data: data, isComplete: isComplete, error: error)
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        guard !isStopped else { return }
        if let error { continuation.finish(throwing: error); return }
        if let data, !data.isEmpty {
            let (chunk, reachedLimit) = delivered.take(data, limit: byteLimit)
            if !chunk.isEmpty {
                enqueue(chunk, reachedLimit: reachedLimit)
                return
            }
            if reachedLimit { continuation.finish(); return }
        }
        if isComplete { continuation.finish(); return }
        receiveNext()
    }

    private func enqueue(_ chunk: Data, reachedLimit: Bool) {
        guard !isStopped else { return }
        switch continuation.yield(chunk) {
        case .enqueued:
            finishOrReceiveNext(reachedLimit: reachedLimit)
        case .dropped(let rejected):
            retryEnqueue(rejected, reachedLimit: reachedLimit)
        case .terminated:
            stop()
        @unknown default:
            stop()
        }
    }

    private func retryEnqueue(_ chunk: Data, reachedLimit: Bool) {
        Task { [self] in
            while !isStopped {
                try? await Task.sleep(for: .milliseconds(5))
                switch continuation.yield(chunk) {
                case .enqueued:
                    finishOrReceiveNext(reachedLimit: reachedLimit)
                    return
                case .dropped:
                    continue
                case .terminated:
                    stop()
                    return
                @unknown default:
                    stop()
                    return
                }
            }
        }
    }

    private func finishOrReceiveNext(reachedLimit: Bool) {
        if reachedLimit {
            continuation.finish()
        } else {
            receiveNext()
        }
    }
}

// MARK: - Support

enum FTPError: Error {
    case unexpected(FTPProtocol.Reply)
    case auth(FTPProtocol.Reply)
    case connectionClosed
    /// The peer sent data that never framed into a valid reply within the buffer bound.
    case protocolError
}

/// A one-shot continuation wrapper for bridging `NWConnection`'s callback API, guarding against a
/// double resume when several state transitions fire.
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var pending: Result<Void, Error>?

    func value() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pending {
                lock.unlock()
                continuation.resume(with: pending)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else if pending == nil {
            pending = result
            lock.unlock()
        } else {
            lock.unlock()
        }
    }
}

/// Tracks bytes delivered so a ranged FTP segment stops after `end - start + 1` bytes (FTP's `REST`
/// only sets a start). Trims the final chunk to the exact boundary.
private final class DeliveredCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int64 = 0

    func take(_ data: Data, limit: Int64?) -> (chunk: Data, reachedLimit: Bool) {
        guard let limit else { return (data, false) }
        lock.lock(); defer { lock.unlock() }
        let remaining = limit - count
        guard remaining > 0 else { return (Data(), true) }
        if Int64(data.count) <= remaining {
            count += Int64(data.count)
            return (data, count >= limit)
        }
        let slice = data.prefix(Int(remaining))
        count = limit
        return (Data(slice), true)
    }
}
