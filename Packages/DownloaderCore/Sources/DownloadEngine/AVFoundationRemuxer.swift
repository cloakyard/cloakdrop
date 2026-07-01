import Foundation
import AVFoundation

/// The production `Remuxer`: repackages the concatenated media into a clean container using
/// AVFoundation's **passthrough** export — no re-encoding, so it's fast and lossless.
///
/// It reads the assembled file as an `AVAsset`, picks the container from the actual track layout
/// (`.mp4` when there's video, `.m4a` for audio-only), and exports the same elementary streams
/// into a proper, seekable file. Inputs AVFoundation can't decode or repackage (e.g. some raw
/// MPEG-TS, or a non-media file) surface as `RemuxError`, and the caller keeps the raw
/// concatenation — which is still playable.
public struct AVFoundationRemuxer: Remuxer {
    public init() {}

    public func remux(sourcePath: String) async throws -> RemuxResult {
        let asset = AVURLAsset(url: URL(fileURLWithPath: sourcePath))

        // Load the tracks; a file AVFoundation can't open throws here → treat as unsupported.
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else { throw RemuxError.unsupported }

        // Video → .mp4; audio-only → .m4a. Passthrough keeps the existing elementary streams.
        let hasVideo = !videoTracks.isEmpty
        let fileType: AVFileType = hasVideo ? .mp4 : .m4a
        let ext = hasVideo ? "mp4" : "m4a"

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw RemuxError.unsupported
        }

        let outputPath = (sourcePath as NSString).deletingPathExtension + ".remuxed.\(ext)"
        try? FileManager.default.removeItem(atPath: outputPath)

        do {
            try await session.export(to: URL(fileURLWithPath: outputPath), as: fileType)
        } catch {
            try? FileManager.default.removeItem(atPath: outputPath)
            throw RemuxError.failed(error.localizedDescription)
        }
        return RemuxResult(outputPath: outputPath, fileExtension: ext)
    }
}
