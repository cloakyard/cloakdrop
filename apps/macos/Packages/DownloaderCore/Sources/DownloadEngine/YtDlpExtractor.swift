import Foundation

/// The production `MediaExtractor`: spawns the bundled **yt-dlp** binary with `-J` (dump-single-json)
/// to resolve a page URL into its formats. yt-dlp only *reads* — it prints JSON to stdout and never
/// touches the destination — so the app's own engine still does every byte of downloading.
///
/// The onedir tree lives in the app bundle (`Contents/Resources/yt-dlp/`, bundled + signed by
/// project.yml's "Bundle & sign yt-dlp" phase) and runs in-sandbox via the app's `inherit`
/// entitlement; use `locate(in:)` to find it. Process spawning is behind `ProcessRunning` so the
/// parse/argument logic is unit-tested without launching anything.
public struct YtDlpExtractor: MediaExtractor {
    private let executableURL: URL
    private let runner: any ProcessRunning
    private let timeout: Duration

    public init(executableURL: URL, runner: any ProcessRunning = SystemProcessRunner(), timeout: Duration = .seconds(60)) {
        self.executableURL = executableURL
        self.runner = runner
        self.timeout = timeout
    }

    /// Locate a bundled `yt-dlp` in `bundle` (the app bundle in production), or `nil` when none is
    /// present/executable — so the app offers page extraction only when it can actually work. Mirrors
    /// `FFmpegMuxer.locate`.
    public static func locate(in bundle: Bundle = .main) -> YtDlpExtractor? {
        // The onedir tree lives at Contents/Resources/yt-dlp/yt-dlp (executable + sibling `_internal/`).
        let candidates = [
            bundle.resourceURL?.appendingPathComponent("yt-dlp/yt-dlp"),
            bundle.url(forAuxiliaryExecutable: "yt-dlp")
        ].compactMap { $0 }
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return YtDlpExtractor(executableURL: url)
        }
        return nil
    }

    public func extract(pageURL: URL, cookies: ExtractionCookies?, userAgent: String?) async throws -> ExtractedMedia {
        var arguments = [
            "-J",                       // dump a single JSON object describing the video + all formats
            "--no-playlist",            // resolve just this video, never a whole playlist/channel
            "--no-warnings",
            "--no-progress",
            "--socket-timeout", "20"
        ]
        if let userAgent, !userAgent.isEmpty { arguments += ["--user-agent", userAgent] }
        switch cookies {
        case .header(let header) where !header.isEmpty:
            arguments += ["--add-header", "Cookie:\(header)"]
        case .file(let url):
            // A Netscape jar keeps per-domain scoping — required for multi-host logins. The file
            // may be updated in place by yt-dlp; callers hand over a private temp copy.
            arguments += ["--cookies", url.path]
        case .header, .none:
            break
        }
        arguments.append(pageURL.absoluteString)

        let result: ProcessRunResult
        do {
            result = try await runner.run(executable: executableURL, arguments: arguments, timeout: timeout)
        } catch let error as MediaExtractionError {
            throw error
        } catch {
            throw MediaExtractionError.toolUnavailable
        }

        guard result.exitCode == 0 else {
            let message = result.stderrTail
            throw MediaExtractionError.failed(message.isEmpty ? "yt-dlp exited \(result.exitCode)" : message)
        }
        guard !result.stdout.isEmpty else { throw MediaExtractionError.invalidOutput }
        return try ExtractedMedia.parse(json: result.stdout)
    }

    public func version() async -> String? {
        guard let result = try? await runner.run(executable: executableURL, arguments: ["--version"], timeout: .seconds(15)),
              result.exitCode == 0 else { return nil }
        let version = (String(bytes: result.stdout, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }
}

// MARK: - System process runner

/// Launches a real subprocess. stdout/stderr are captured to temp files (never `Pipe`s), so a large
/// dump — YouTube's `-J` output runs to several MB — can't fill a pipe buffer and deadlock the child.
/// Mirrors `FFmpegMuxer`'s spawn, adding a hard timeout that terminates a hung process.
public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: URL, arguments: [String], timeout: Duration) async throws -> ProcessRunResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw MediaExtractionError.toolUnavailable
        }
        let tmp = FileManager.default.temporaryDirectory
        let outURL = tmp.appendingPathComponent("cloakdrop-proc-\(UUID().uuidString).out")
        let errURL = tmp.appendingPathComponent("cloakdrop-proc-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outURL); try? FileManager.default.removeItem(at: errURL) }

        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle

        let box = UncheckedBox(process)
        let resume = ResumeGuard()
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
                let timeoutTask = Task {
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    resume.once { continuation.resume(throwing: MediaExtractionError.timedOut) }
                    if box.value.isRunning { box.value.terminate() }
                }
                process.terminationHandler = { finished in
                    timeoutTask.cancel()
                    resume.once { continuation.resume(returning: finished.terminationStatus) }
                }
                do {
                    // A cancel that lands before launch must not spawn the process at all — and
                    // `terminate()` on a never-launched Process raises, so `onCancel` guards too.
                    try Task.checkCancellation()
                    try process.run()
                } catch {
                    timeoutTask.cancel()
                    resume.once { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            if box.value.isRunning { box.value.terminate() }
        }

        try? outHandle.close()
        try? errHandle.close()
        withExtendedLifetime(process) {}
        let stdout = (try? Data(contentsOf: outURL)) ?? Data()
        let stderr = (try? Data(contentsOf: errURL)) ?? Data()
        return ProcessRunResult(exitCode: status, stdout: stdout, stderr: stderr)
    }
}

/// Carries a non-`Sendable` value (here, `Process`) across the continuation/timeout boundary. Only its
/// thread-safe `terminate()`/`isRunning` are touched off the launching task.
private final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Ensures a continuation resumes exactly once, whichever of {termination, timeout, launch-failure}
/// happens first.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func once(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
