import Foundation
import Testing
@testable import DownloadModels

@Suite("Persisted model input safety")
struct ModelInputSafetyTests {
    @Test("Unsafe persisted segment offsets and progress are rejected before arithmetic", arguments: [
        ["id": Int64(-1), "start": 0, "end": 99, "downloadedBytes": 0],
        ["id": 0, "start": -1, "end": 99, "downloadedBytes": 0],
        ["id": 0, "start": 100, "end": 99, "downloadedBytes": 0],
        ["id": 0, "start": 0, "end": Int64.max, "downloadedBytes": 0],
        ["id": 0, "start": 0, "end": 99, "downloadedBytes": -1],
        ["id": 0, "start": 0, "end": 99, "downloadedBytes": 101],
        ["id": 0, "start": Int64.max - 2, "end": Int64.max - 1, "downloadedBytes": Int64.max]
    ])
    func rejectsInvalidSegments(_ values: [String: Int64]) throws {
        let data = try JSONEncoder().encode(values)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(DownloadSegment.self, from: data) }
    }

    @Test("Largest safe and unknown-size segments still round-trip")
    func preservesSafeSegments() throws {
        for segment in [
            DownloadSegment(id: 0, start: 0, end: Int64.max - 1),
            DownloadSegment(id: Int.max, start: Int64.max - 2, end: Int64.max - 1, downloadedBytes: 2)
        ] {
            let decoded = try JSONDecoder().decode(DownloadSegment.self, from: JSONEncoder().encode(segment))
            #expect(decoded == segment)
            #expect(decoded.currentOffset >= 0)
            #expect(decoded.remainingBytes >= 0)
        }
    }

    @Test("Persisted media ranges cannot be negative, empty or overflow", arguments: [
        ["offset": Int64(-1), "length": 1],
        ["offset": 0, "length": 0],
        ["offset": 0, "length": -1],
        ["offset": Int64.max, "length": 1],
        ["offset": 2, "length": Int64.max]
    ])
    func rejectsInvalidMediaRanges(_ values: [String: Int64]) throws {
        let data = try JSONEncoder().encode(values)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(MediaByteRange.self, from: data) }
    }

    @Test("The largest safe persisted media range remains readable")
    func preservesSafeMediaRange() throws {
        let range = MediaByteRange(offset: 1, length: Int64.max - 1)
        let decoded = try JSONDecoder().decode(MediaByteRange.self, from: JSONEncoder().encode(range))
        #expect(decoded == range)
        #expect(decoded.end == Int64.max - 1)
    }

    @Test("Corrupt aggregate counters saturate without crashing catalog rendering")
    func boundsAggregateCounters() {
        let download = Download(
            url: URL(string: "https://example.com/file")!, fileName: "file", destinationDirectoryPath: "/tmp",
            totalBytes: Int64.max,
            segments: (0..<2).map { DownloadSegment(id: $0, start: 0, end: Int64.max - 1, downloadedBytes: Int64.max) }
        )
        #expect(download.downloadedBytes == Int64.max)
        #expect(download.fractionCompleted == 1)
        let progress = DownloadProgress(id: UUID(), downloadedBytes: .min, totalBytes: .max, bytesPerSecond: 2)
        #expect(progress.fractionCompleted == 0)
        #expect(progress.estimatedTimeRemaining == Double(Int64.max) / 2)
        #expect(DownloadProgress(id: UUID(), downloadedBytes: 0, totalBytes: 100,
                                 bytesPerSecond: .infinity).estimatedTimeRemaining == nil)
    }

    @Test("Quality ranking handles extreme decoded dimensions without integer overflow")
    func boundsQualityRanking() throws {
        let extreme = MediaResolution(width: Int.max, height: Int.max)
        let decoded = try JSONDecoder().decode(MediaResolution.self, from: JSONEncoder().encode(extreme))
        #expect(decoded.pixelCount == Int.max)
        #expect(decoded.qualityHeight == Int.max)
        #expect(MediaResolution(width: Int.max, height: 1).qualityHeight > 0)
        #expect(MediaResolution(width: Int.min, height: Int.min).pixelCount == 0)
        #expect(MediaResolution(width: Int.min, height: Int.min).qualityHeight == 0)
    }
}
