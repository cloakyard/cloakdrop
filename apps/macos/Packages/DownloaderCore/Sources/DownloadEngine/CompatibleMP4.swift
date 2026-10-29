import AVFoundation
import AudioToolbox
import Foundation

/// Verify the downloaded tracks, not just extractor metadata or file extensions, before MP4 export.
enum CompatibleMP4 {
    static func validate(videoPath: String, audioPath: String? = nil) async throws {
        let videoAsset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
        let videos = try await videoAsset.loadTracks(withMediaType: .video)
        guard !videos.isEmpty else { throw RemuxError.unsupported }
        try await requireCodec(kCMVideoCodecType_H264, in: videos)
        let audioAsset = audioPath.map { AVURLAsset(url: URL(fileURLWithPath: $0)) } ?? videoAsset
        let audios = try await audioAsset.loadTracks(withMediaType: .audio)
        if audioPath != nil, audios.isEmpty { throw RemuxError.unsupported }
        try await requireCodec(kAudioFormatMPEG4AAC, in: audios)
    }

    private static func requireCodec(_ codec: FourCharCode, in tracks: [AVAssetTrack]) async throws {
        for track in tracks {
            let descriptions = try await track.load(.formatDescriptions)
            guard !descriptions.isEmpty,
                  descriptions.allSatisfy({ CMFormatDescriptionGetMediaSubType($0) == codec }) else {
                throw RemuxError.unsupported
            }
        }
    }
}
