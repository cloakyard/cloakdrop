import Foundation
import DownloadModels

public extension ExtractedMedia {
    /// An audio site's HLS media playlist may omit CODECS entirely. Preserve the extractor's
    /// explicit audio-only evidence so the picker and persisted plan do not turn it into video.
    /// Never infer this from the absence of dimensions or from a single audio rendition of a video.
    func applyingAudioIdentity(to stream: MediaStream) -> MediaStream {
        guard !formats.isEmpty, formats.allSatisfy(\.isAudioOnly),
              !stream.variants.contains(where: \.hasVideo) else { return stream }
        var result = stream
        result.variants = stream.variants.map { variant in
            MediaVariant(
                id: variant.id, bandwidth: variant.bandwidth, resolution: variant.resolution,
                codecs: variant.codecs, frameRate: variant.frameRate, playlistURL: variant.playlistURL,
                audioGroupID: variant.audioGroupID, subtitleGroupID: variant.subtitleGroupID,
                initSegment: variant.initSegment, segments: variant.segments, videoTrackPresent: false
            )
        }
        return result
    }
}
