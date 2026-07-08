import Foundation

/// Repackages a grabbed media stream into a clean, widely-playable container.
///
/// A media grab first concatenates its segments into a single file. That file is *playable*
/// (a fragmented MP4 or an MPEG-TS stream), but it isn't a clean container: a fragmented MP4
/// has no top-level index for fast seeking, and a `.ts` stream isn't what most tools expect.
/// A `Remuxer` turns it into a proper `.mp4`/`.m4a` **without re-encoding** (a fast, lossless
/// repackage), so the finished file seeks cleanly and carries the right extension.
///
/// It sits behind a protocol so the AVFoundation implementation is swappable (a future ffmpeg
/// fallback for containers AVFoundation can't mux) and so tests can inject a deterministic one.
public protocol Remuxer: Sendable {
    /// Repackage the concatenated media at `sourcePath` into a clean container.
    ///
    /// Returns the produced file plus the container it chose (`mp4` for video, `m4a` for
    /// audio-only). Throws `RemuxError` when the input can't be repackaged — the caller then
    /// keeps the raw concatenation, which is still playable. Implementations must not mutate or
    /// remove `sourcePath`; the caller owns its lifecycle.
    func remux(sourcePath: String) async throws -> RemuxResult

    /// Combine a separate video-only file and audio-only file into one clean container carrying
    /// both tracks — how an adaptive source's split video/audio streams become a single playable
    /// file, so a "video" download always has sound. Throws `RemuxError.unsupported` when this
    /// muxer can't combine the given codecs (the AVFoundation implementation handles H.264/HEVC +
    /// AAC; VP9/AV1/Opus need the ffmpeg backend). Neither input is mutated.
    func mux(videoPath: String, audioPath: String) async throws -> RemuxResult
}

public extension Remuxer {
    /// Default: no muxing capability (the passthrough/test remuxer). Callers fall back to shipping
    /// the video-only file when this throws.
    func mux(videoPath: String, audioPath: String) async throws -> RemuxResult {
        throw RemuxError.unsupported
    }
}

/// The outcome of a successful remux: the file to hand to the destination and the container's
/// file extension (so the caller can correct the download's name and category to match).
public struct RemuxResult: Sendable, Equatable {
    /// Absolute path of the produced file (may equal the source when no repackaging was needed).
    public let outputPath: String
    /// The chosen container's extension without the dot — `"mp4"` or `"m4a"`.
    public let fileExtension: String

    public init(outputPath: String, fileExtension: String) {
        self.outputPath = outputPath
        self.fileExtension = fileExtension
    }
}

public enum RemuxError: Error, Sendable, Equatable {
    /// The input isn't something this remuxer can repackage (not decodable, no A/V tracks, or an
    /// incompatible preset/container combination). The caller should fall back to the raw file.
    case unsupported
    /// The remux was attempted but failed midway.
    case failed(String)
}

/// A `Remuxer` that tries an ordered list of backends and uses the first that succeeds. Each
/// operation runs every backend in turn, falling through to the next on **any** throw
/// (`.unsupported` or `.failed`), and only rethrows the last backend's error when they all fail.
///
/// This is how CloakDrop pairs a fast in-process backend with a heavier, more capable one:
/// `AVFoundationRemuxer` first (no subprocess, no bundled dependency — handles H.264/HEVC + AAC),
/// then a bundled `FFmpegMuxer` for the codecs AVFoundation rejects (VP9/AV1/Opus). A "video" grab
/// gets its audio muxed in whenever *either* backend can do it, and only ships video-only when
/// neither can.
public struct CompositeRemuxer: Remuxer {
    private let remuxers: [any Remuxer]

    /// Order matters: earlier backends are preferred, later ones are fallbacks. An empty list makes
    /// every operation throw `.unsupported`.
    public init(_ remuxers: [any Remuxer]) {
        self.remuxers = remuxers
    }

    public func remux(sourcePath: String) async throws -> RemuxResult {
        try await firstSuccess { try await $0.remux(sourcePath: sourcePath) }
    }

    public func mux(videoPath: String, audioPath: String) async throws -> RemuxResult {
        try await firstSuccess { try await $0.mux(videoPath: videoPath, audioPath: audioPath) }
    }

    /// Run `operation` against each backend in order, returning the first success and remembering the
    /// most recent error to rethrow if every backend fails.
    private func firstSuccess(_ operation: (any Remuxer) async throws -> RemuxResult) async throws -> RemuxResult {
        var lastError: any Error = RemuxError.unsupported
        for remuxer in remuxers {
            do {
                return try await operation(remuxer)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}

/// A `Remuxer` that performs **no** repackaging: it returns the concatenation unchanged. Used as
/// the deterministic remuxer in tests and as an explicit opt-out where a clean container isn't
/// wanted. The `fileExtension` reflects the source file's own extension, so the caller's
/// name/category correction is a no-op.
public struct PassthroughRemuxer: Remuxer {
    public init() {}

    public func remux(sourcePath: String) async throws -> RemuxResult {
        RemuxResult(outputPath: sourcePath, fileExtension: (sourcePath as NSString).pathExtension)
    }
}
