import Foundation
import DownloadModels

/// One in-flight URLSession task's continuations and bounded pending-body state.
struct TaskHandler {
    let data: AsyncThrowingStream<Data, Error>.Continuation
    var head: CheckedContinuation<HTTPResponseHead, Error>?
    var pendingData: [Data] = []
    var isSuspended = false
    var didFinish = false
    var finishError: (any Error)?
}

/// Lock-guarded map from `ObjectIdentifier(URLSessionTask)` to its handler. Bridges the
/// delegate's serial queue to async callers while enforcing bounded producer backpressure. Numeric
/// task identifiers restart in each session; old callbacks after a proxy change must never resolve
/// or cancel a replacement session's request with the same number.
final class TaskRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [ObjectIdentifier: TaskHandler] = [:]

    func register(taskID: ObjectIdentifier, handler: TaskHandler) {
        lock.lock(); defer { lock.unlock() }
        handlers[taskID] = handler
    }

    func remove(taskID: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        handlers[taskID] = nil
    }

    /// Resolve the head continuation exactly once.
    func completeHead(taskID: ObjectIdentifier, with result: Result<HTTPResponseHead, Error>) {
        lock.lock()
        guard var handler = handlers[taskID], let head = handler.head else { lock.unlock(); return }
        handler.head = nil
        handlers[taskID] = handler
        lock.unlock()
        head.resume(with: result)
    }

    /// Yield a body chunk. Returns true exactly once when the stream buffer fills and the caller must
    /// suspend its URLSession task; `drainPending` owns the matching resume.
    func yield(taskID: ObjectIdentifier, data: Data) -> Bool {
        lock.lock()
        guard var handler = handlers[taskID] else { lock.unlock(); return false }
        if handler.isSuspended {
            // At most a tiny number of delegate callbacks can already be queued when suspension takes
            // effect. Preserve them in order; no new socket reads are issued while suspended.
            handler.pendingData.append(data)
            handlers[taskID] = handler
            lock.unlock()
            return false
        }
        let continuation = handler.data
        lock.unlock()

        switch continuation.yield(data) {
        case .enqueued:
            return false
        case .dropped(let rejected):
            lock.lock()
            guard var current = handlers[taskID] else { lock.unlock(); return false }
            current.pendingData.append(rejected)
            current.isSuspended = true
            handlers[taskID] = current
            lock.unlock()
            return true
        case .terminated:
            return false
        @unknown default:
            return false
        }
    }

    /// Retry a chunk rejected by the bounded AsyncStream until the consumer frees capacity, then
    /// resume the underlying request. This is real producer backpressure: a speed cap or slow disk no
    /// longer lets URLSession buffer an entire large download in process memory.
    func drainPending(taskID: ObjectIdentifier, task dataTask: URLSessionDataTask) {
        Task { [weak self, weak dataTask] in
            guard let self, let dataTask else { return }
            while true {
                try? await Task.sleep(for: .milliseconds(5))
                switch self.nextDrainAction(taskID: taskID) {
                case .stop:
                    return
                case .resume:
                    dataTask.resume()
                    return
                case .finish(let continuation, let error):
                    if let error { continuation.finish(throwing: error) } else { continuation.finish() }
                    return
                case .retry(let continuation, let next):
                    switch continuation.yield(next) {
                    case .enqueued:
                        self.removeAcceptedPendingChunk(taskID: taskID)
                    case .dropped:
                        continue
                    case .terminated:
                        return
                    @unknown default:
                        return
                    }
                }
            }
        }
    }

    private enum DrainAction {
        case stop
        case resume
        case finish(AsyncThrowingStream<Data, Error>.Continuation, (any Error)?)
        case retry(AsyncThrowingStream<Data, Error>.Continuation, Data)
    }

    /// Synchronous lock scope kept outside the async drain task (`NSLock.lock()` is intentionally
    /// unavailable directly from async contexts under Swift 6).
    private func nextDrainAction(taskID: ObjectIdentifier) -> DrainAction {
        lock.withLock {
            guard var handler = handlers[taskID] else { return .stop }
            guard let next = handler.pendingData.first else {
                if handler.didFinish {
                    handlers[taskID] = nil
                    return .finish(handler.data, handler.finishError)
                }
                handler.isSuspended = false
                handlers[taskID] = handler
                return .resume
            }
            return .retry(handler.data, next)
        }
    }

    private func removeAcceptedPendingChunk(taskID: ObjectIdentifier) {
        lock.withLock {
            guard var handler = handlers[taskID], !handler.pendingData.isEmpty else { return }
            handler.pendingData.removeFirst()
            handlers[taskID] = handler
        }
    }

    func finish(taskID: ObjectIdentifier, error: (any Error)?) {
        lock.lock()
        guard var handler = handlers[taskID] else { lock.unlock(); return }
        let classifiedError = error.map(Self.classify)
        // URLSession can already have data/completion callbacks queued when suspend() takes effect.
        // Preserve rejected chunks and let the active drainer finish them before closing the stream.
        if !handler.pendingData.isEmpty {
            let head = handler.head
            handler.head = nil
            handler.didFinish = true
            handler.finishError = classifiedError
            handlers[taskID] = handler
            lock.unlock()
            if let head {
                head.resume(throwing: classifiedError ?? DownloadError.canceled)
            }
            return
        }
        handlers[taskID] = nil
        lock.unlock()
        // If the response never arrived, surface the failure to the awaiting head call too.
        if let head = handler.head {
            head.resume(throwing: classifiedError ?? DownloadError.canceled)
        }
        if let classifiedError {
            handler.data.finish(throwing: classifiedError)
        } else {
            handler.data.finish()
        }
    }

    private static func classify(_ error: any Error) -> any Error {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled:
                return DownloadError.canceled
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut:
                return DownloadError.networkLost
            default:
                break
            }
        }
        return error
    }
}
