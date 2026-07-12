import Foundation
import AVFoundation

/// Synthesizes genuine (tiny) media with AVFoundation for engine tests — no network and no
/// committed binary fixtures. Shared by the remux and thumbnail suites.
enum MediaFixtures {
    enum FixtureError: Error { case setup }

    /// Write `frames` frames of solid-gray H.264 video into an MP4 at `url` (320×240, 30fps).
    static func writeVideoMP4(to url: URL, frames: Int = 12) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 240
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB]
        )
        guard writer.canAdd(input) else { throw FixtureError.setup }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FixtureError.setup }
        writer.startSession(atSourceTime: .zero)

        let fps: Int32 = 30
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            let buffer = try makePixelBuffer(width: 320, height: 240, fill: UInt8(truncatingIfNeeded: index * 20))
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps)) else {
                throw writer.error ?? FixtureError.setup
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error ?? FixtureError.setup }
    }

    /// Write ~0.5s of silent AAC audio into an `.m4a` at `url`.
    static func writeAudioM4A(to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1
        ])
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 22_050) else {
            throw FixtureError.setup
        }
        buffer.frameLength = 22_050   // silence (zero-filled) is enough to make a real audio track
        try file.write(from: buffer)
    }

    private static func makePixelBuffer(width: Int, height: Int, fill: UInt8) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { throw FixtureError.setup }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(fill), CVPixelBufferGetBytesPerRow(buffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
