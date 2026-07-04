import Foundation

/// A `ProcessRunning` that returns canned output instead of launching anything — lets `YtDlpExtractor`
/// be tested end to end (argument building, exit-code handling, JSON parsing) with no subprocess.
public final class MockProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _lastArguments: [String] = []

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

    public func run(executable: URL, arguments: [String], timeout: Duration) async throws -> ProcessRunResult {
        let error: MediaExtractionError? = lock.withLock {
            _lastArguments = arguments
            return throwing
        }
        if let error { throw error }
        return ProcessRunResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }
}
