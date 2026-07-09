import Foundation

/// A `Remuxer` backed by a bundled **ffmpeg** binary, for the containers AVFoundation can't mux or
/// repackage without re-encoding — VP9/AV1 video and Opus audio (YouTube WebM, high-resolution
/// adaptive renditions). It shells out to ffmpeg with stream-copy (`-c copy`), so it stays a fast,
/// lossless repackage — just like the AVFoundation path — into a Matroska (`.mkv`) container, which
/// carries any codec combination the exotic renditions throw at it.
///
/// It's the fallback tier behind `AVFoundationRemuxer` in a `CompositeRemuxer`: the common
/// H.264/HEVC + AAC case stays in-process (no subprocess, no bundled dependency), and ffmpeg only
/// runs when the first backend reports it can't handle the codecs. When no runnable binary is
/// present (`executableURL` doesn't point at an executable), every operation throws `.unsupported`
/// so the composite falls through cleanly — the app simply behaves as if only AVFoundation existed.
///
/// The binary lives inside the app bundle and is spawned in-sandbox; use `locate(in:)` to find it.
public struct FFmpegMuxer: Remuxer {
    private let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    /// Locate a bundled `ffmpeg` in `bundle` (the app bundle in production). Looks for it as a
    /// resource (`ffmpeg` with no extension) and as an auxiliary executable (`Contents/Helpers`).
    /// Returns `nil` when none is present or it isn't executable, so the caller can omit the ffmpeg
    /// tier and rely on AVFoundation alone.
    public static func locate(in bundle: Bundle = .main) -> FFmpegMuxer? {
        let candidates = [
            bundle.url(forResource: "ffmpeg", withExtension: nil),
            bundle.url(forAuxiliaryExecutable: "ffmpeg")
        ]
        for case let url? in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return FFmpegMuxer(executableURL: url)
        }
        return nil
    }

    public func remux(sourcePath: String) async throws -> RemuxResult {
        let output = (sourcePath as NSString).deletingPathExtension + ".remuxed.mkv"
        try await run(arguments: ["-nostdin", "-y", "-i", sourcePath, "-c", "copy", output], output: output)
        return RemuxResult(outputPath: output, fileExtension: "mkv")
    }

    public func mux(videoPath: String, audioPath: String) async throws -> RemuxResult {
        let output = (videoPath as NSString).deletingPathExtension + ".muxed.mkv"
        // Take video from input 0 and audio from input 1, stream-copied into Matroska. `-shortest`
        // clamps the result to the shorter of the two tracks so a length mismatch can't desync the
        // audio or leave a trailing silent/black tail (mirrors the AVFoundation path's clamp).
        try await run(
            arguments: [
                "-nostdin", "-y",
                "-i", videoPath, "-i", audioPath,
                "-map", "0:v:0", "-map", "1:a:0",
                "-c", "copy", "-shortest", output
            ],
            output: output
        )
        return RemuxResult(outputPath: output, fileExtension: "mkv")
    }

    /// Run ffmpeg with `arguments`, clearing a stale `output` first (and on failure). Throws
    /// `.unsupported` when the binary can't be launched (so a `CompositeRemuxer` falls through to the
    /// next backend) and `.failed` — with the tail of ffmpeg's stderr — when it exits nonzero or
    /// produces no file.
    private func run(arguments: [String], output: String) async throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw RemuxError.unsupported
        }
        try? FileManager.default.removeItem(atPath: output)

        // ffmpeg is verbose; capture stderr to a temp file (not a Pipe) so a full pipe buffer can
        // never deadlock the child on a long transfer, then keep only the tail for diagnostics.
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloakdrop-ffmpeg-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: logURL) }

        let status: Int32
        do {
            status = try await Self.execute(executableURL: executableURL, arguments: arguments, stderrLog: logURL)
        } catch is CancellationError {
            try? FileManager.default.removeItem(atPath: output)
            throw CancellationError()
        } catch {
            // Failed to even launch the process → treat as unsupported so the composite can recover.
            try? FileManager.default.removeItem(atPath: output)
            throw RemuxError.unsupported
        }

        guard status == 0 else {
            try? FileManager.default.removeItem(atPath: output)
            // A cancel-killed child exits nonzero — report the cancellation, not a codec failure,
            // so callers don't fall through to a "ship it without audio" recovery path.
            try Task.checkCancellation()
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            throw RemuxError.failed("ffmpeg exited \(status): \(String(log.suffix(500)))")
        }
        // A zero exit with no output file (some malformed inputs) is still a failure for us.
        guard FileManager.default.fileExists(atPath: output) else {
            throw RemuxError.failed("ffmpeg exited 0 but produced no output")
        }
    }

    /// Launch ffmpeg and await its termination, returning the exit status. stdin/stdout are silenced;
    /// stderr is redirected to `stderrLog`. Cooperative: cancelling the awaiting task terminates the
    /// child (a multi-GB mux must not outlive a cancelled download). Throws only if the process can't
    /// be launched or the task was cancelled before launch.
    private static func execute(executableURL: URL, arguments: [String], stderrLog: URL) async throws -> Int32 {
        let errorHandle = try FileHandle(forWritingTo: stderrLog)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorHandle
        // Keep `process` and `errorHandle` alive across the suspension until the child has exited,
        // and close the log handle once it has.
        defer {
            try? errorHandle.close()
            withExtendedLifetime(process) {}
        }
        let box = UncheckedProcessBox(process)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
                // `terminationHandler` is @Sendable and captures only the (Sendable) continuation; it
                // reads the status off the process passed into it, never the captured local.
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    // A cancel that lands before launch must not start a mux at all — and
                    // `terminate()` on a never-launched Process raises, so `onCancel` guards too.
                    try Task.checkCancellation()
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if box.value.isRunning { box.value.terminate() }
        }
    }
}

/// Carries the non-`Sendable` `Process` into the cancellation handler. Only its thread-safe
/// `isRunning`/`terminate()` are touched off the launching task.
private final class UncheckedProcessBox: @unchecked Sendable {
    let value: Process
    init(_ value: Process) { self.value = value }
}
