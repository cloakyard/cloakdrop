import Foundation

public extension MediaStream {
    /// HLS declares the codecs of both the video and its referenced audio group in CODECS.
    /// Offer lossless MP4 only with explicit H.264/AAC-LC evidence and a resolvable audio group.
    /// DASH lists audio codecs separately; unknown/inline playlists need other codec evidence.
    /// The remuxer still validates the actual downloaded tracks before publication.
    var compatibleMP4Stream: MediaStream? {
        guard format == .hls else { return nil }
        let compatible = variants.filter { variant in
            let codecs = variant.codecs.map { $0.lowercased() }
            func isH264(_ codec: String) -> Bool {
                ["avc1", "avc2", "avc3", "avc4"].contains(String(codec.prefix { $0 != "." }))
            }
            guard variant.hasVideo, codecs.contains(where: isH264), codecs.contains("mp4a.40.2"),
                  codecs.allSatisfy({ isH264($0) || $0 == "mp4a.40.2" }) else { return false }
            if let group = variant.audioGroupID { return audioTracks.contains { $0.groupID == group } }
            return true
        }
        guard !compatible.isEmpty else { return nil }
        let groups = Set(compatible.compactMap(\.audioGroupID))
        return MediaStream(sourceURL: sourceURL, format: format, variants: compatible,
                           audioTracks: audioTracks.filter { $0.groupID.map(groups.contains) == true },
                           subtitleTracks: subtitleTracks)
    }
}
