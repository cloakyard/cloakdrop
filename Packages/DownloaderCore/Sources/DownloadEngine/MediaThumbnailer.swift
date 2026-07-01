import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Renders a poster-frame thumbnail for a finished video file.
///
/// UI-agnostic on purpose: it returns JPEG **data**, so the app layer owns caching and display
/// (the engine never imports SwiftUI/AppKit). It gives a completed media grab a real preview
/// instead of a generic file glyph, and pairs with the 4c remux — it needs a finished, seekable
/// file to sample a frame from.
public enum MediaThumbnailer {
    public enum ThumbnailError: Error, Sendable { case noVideoTrack, generationFailed, encodingFailed }

    /// Render a thumbnail from `fileURL`, scaled to fit `maxDimension` px on its longest side,
    /// encoded as JPEG. Samples a frame a little into the clip to avoid a black opening frame.
    /// Throws `.noVideoTrack` for audio-only files (the caller then keeps the file glyph).
    public static func generateJPEG(for fileURL: URL, maxDimension: Int = 480, quality: Double = 0.8) async throws -> Data {
        let asset = AVURLAsset(url: fileURL)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw ThumbnailError.noVideoTrack
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true    // honour rotation metadata
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let seconds = duration.isFinite && duration > 0 ? min(1.0, duration / 2) : 0
        let time = CMTime(seconds: seconds, preferredTimescale: 600)

        let cgImage: CGImage
        do {
            cgImage = try await generator.image(at: time).image
        } catch {
            throw ThumbnailError.generationFailed
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw ThumbnailError.encodingFailed }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ThumbnailError.encodingFailed }
        return data as Data
    }
}
