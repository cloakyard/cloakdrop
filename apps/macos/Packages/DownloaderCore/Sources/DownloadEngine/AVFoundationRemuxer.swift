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
        try await requireSafeVideoPassthrough(videoTracks)

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

    public func mux(videoPath: String, audioPath: String) async throws -> RemuxResult {
        let videoAsset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
        let audioAsset = AVURLAsset(url: URL(fileURLWithPath: audioPath))

        // Both tracks are copied into one composition, then exported passthrough (no re-encode).
        // Recognizing a track does not prove safe passthrough: Apple's AV1 exporter can succeed
        // while doubling sample durations. Inspect the codec before building the composition.
        guard let sourceVideo = (try? await videoAsset.loadTracks(withMediaType: .video))?.first else {
            throw RemuxError.unsupported
        }
        try await requireSafeVideoPassthrough([sourceVideo])
        // Audio is mandatory: the whole point of muxing is to give the video sound. If AVFoundation
        // can't read the audio (e.g. Opus), report `.unsupported` and let the ffmpeg backend mux it
        // rather than silently exporting a soundless video — which would satisfy the caller and
        // strand the download without audio.
        guard let sourceAudio = (try? await audioAsset.loadTracks(withMediaType: .audio))?.first else {
            throw RemuxError.unsupported
        }
        let videoDuration = (try? await videoAsset.load(.duration)) ?? .zero
        let audioDuration = (try? await audioAsset.load(.duration)) ?? videoDuration

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RemuxError.unsupported
        }
        do {
            try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: sourceVideo, at: .zero)
            // Clamp audio to the video's length so a slightly longer/shorter track can't skew A/V sync.
            let span = CMTimeMinimum(videoDuration, audioDuration)
            try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: span), of: sourceAudio, at: .zero)
        } catch {
            throw RemuxError.unsupported     // couldn't assemble these tracks → let ffmpeg try
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw RemuxError.unsupported
        }
        let outputPath = (videoPath as NSString).deletingPathExtension + ".muxed.mp4"
        try? FileManager.default.removeItem(atPath: outputPath)
        do {
            try await session.export(to: URL(fileURLWithPath: outputPath), as: .mp4)
        } catch {
            try? FileManager.default.removeItem(atPath: outputPath)
            throw RemuxError.failed(error.localizedDescription)
        }
        return RemuxResult(outputPath: outputPath, fileExtension: "mp4")
    }

    /// Limit Apple's video passthrough to the codecs verified by this backend. AV1/VP9 belong to
    /// FFmpeg even when AVFoundation can decode them or reports a successful MP4 export.
    private func requireSafeVideoPassthrough(_ tracks: [AVAssetTrack]) async throws {
        for track in tracks {
            let descriptions = try await track.load(.formatDescriptions)
            guard !descriptions.isEmpty, descriptions.allSatisfy({ description in
                let codec = CMFormatDescriptionGetMediaSubType(description)
                return codec == kCMVideoCodecType_H264 || codec == kCMVideoCodecType_HEVC
            }) else { throw RemuxError.unsupported }
        }
    }
}
