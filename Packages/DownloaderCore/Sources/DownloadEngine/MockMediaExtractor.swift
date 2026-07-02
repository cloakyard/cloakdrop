import Foundation

/// A `ProcessRunning` that returns canned output instead of launching anything — lets `YtDlpExtractor`
/// be tested end to end (argument building, exit-code handling, JSON parsing) with no subprocess.
public final class MockProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _lastExecutable: URL?
    private var _lastArguments: [String] = []
    private var _runCount = 0

    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    /// When set, `run` throws this instead of returning — to exercise the timeout / launch-failure paths.
    public var throwing: MediaExtractionError?

    public init(exitCode: Int32 = 0, stdout: Data = Data(), stderr: Data = Data(), throwing: MediaExtractionError? = nil) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.throwing = throwing
    }

    public convenience init(json: String) {
        self.init(exitCode: 0, stdout: Data(json.utf8))
    }

    public var lastArguments: [String] { lock.withLock { _lastArguments } }
    public var lastExecutable: URL? { lock.withLock { _lastExecutable } }
    public var runCount: Int { lock.withLock { _runCount } }

    public func run(executable: URL, arguments: [String], timeout: Duration) async throws -> ProcessRunResult {
        let error: MediaExtractionError? = lock.withLock {
            _lastExecutable = executable
            _lastArguments = arguments
            _runCount += 1
            return throwing
        }
        if let error { throw error }
        return ProcessRunResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }
}

/// An in-memory `MediaExtractor` for previews and app-layer tests: hand it a fixed result (or error)
/// to return, and it records the last `extract` inputs.
public final class MockMediaExtractor: MediaExtractor, @unchecked Sendable {
    private let lock = NSLock()
    private var _lastPageURL: URL?
    private var _lastCookies: String?
    private var _lastUserAgent: String?

    public var result: Result<ExtractedMedia, MediaExtractionError>
    public var versionString: String?

    public init(result: Result<ExtractedMedia, MediaExtractionError>, version: String? = "mock") {
        self.result = result
        self.versionString = version
    }

    public var lastPageURL: URL? { lock.withLock { _lastPageURL } }
    public var lastCookies: String? { lock.withLock { _lastCookies } }
    public var lastUserAgent: String? { lock.withLock { _lastUserAgent } }

    public func extract(pageURL: URL, cookies: String?, userAgent: String?) async throws -> ExtractedMedia {
        lock.withLock { _lastPageURL = pageURL; _lastCookies = cookies; _lastUserAgent = userAgent }
        return try result.get()
    }

    public func version() async -> String? { versionString }
}
