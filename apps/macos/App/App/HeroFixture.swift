#if DEBUG
import Foundation
import DownloadModels

/// Stable sample data for native product captures. Launch a Debug build with `--hero-fixture` to
/// render this snapshot without network access, temporary files, or mutations to the real catalog.
struct HeroFixtureState {
    let downloads: [Download]
    let activeDownloadID: UUID
    let progress: DownloadProgress

    static func make() -> HeroFixtureState {
        let activeID = identifier("00000000-0000-0000-0000-000000000100")
        let totalBytes: Int64 = 6_518_974_464
        let segmentLength = totalBytes / 8
        let segmentPercentages: [Int64] = [58, 62, 57, 63, 36, 66, 64, 64]
        let segments = segmentPercentages.enumerated().map { index, percentage in
            let start = Int64(index) * segmentLength
            return DownloadSegment(
                id: index,
                start: start,
                end: start + segmentLength - 1,
                downloadedBytes: segmentLength * percentage / 100
            )
        }
        let createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let active = Download(
            id: activeID,
            url: url("https://releases.ubuntu.com/26.04/ubuntu-26.04-desktop-amd64.iso"),
            fileName: "ubuntu-26.04-desktop-amd64.iso",
            destinationDirectoryPath: "/Users/example/Downloads",
            totalBytes: totalBytes,
            supportsResume: true,
            segments: segments,
            status: .downloading,
            peakBytesPerSecond: 81_700_000,
            activeSeconds: 75.84,
            createdAt: createdAt,
            startedAt: createdAt,
            order: 0
        )

        let examples: [(String, Int64)] = [
            ("lofi-beats-to-debug-to.m4a", 50_300_000),
            ("final-final-v3-ACTUALLY-final.pdf", 12_600_000),
            ("my-entire-music-library.zip", 268_400_000),
            ("wallpaper-8k-definitely-overkill.png", 100_700_000),
            ("rewrite-it-in-rust.dmg", 188_700_000)
        ]
        let completed = examples.enumerated().map { index, example in
            completedDownload(
                id: identifier(String(format: "00000000-0000-0000-0000-%012d", index + 101)),
                fileName: example.0,
                totalBytes: example.1,
                createdAt: createdAt.addingTimeInterval(-Double(index + 1)),
                order: index + 1
            )
        }
        let progress = DownloadProgress(
            id: activeID,
            downloadedBytes: 3_830_000_000,
            totalBytes: totalBytes,
            bytesPerSecond: 67_200_000,
            peakBytesPerSecond: 81_700_000,
            averageBytesPerSecond: 50_500_000,
            segmentBytes: Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0.downloadedBytes) })
        )
        return HeroFixtureState(
            downloads: [active] + completed,
            activeDownloadID: activeID,
            progress: progress
        )
    }

    private static func completedDownload(
        id: UUID,
        fileName: String,
        totalBytes: Int64,
        createdAt: Date,
        order: Int
    ) -> Download {
        Download(
            id: id,
            url: url("https://example.invalid/\(fileName)"),
            fileName: fileName,
            destinationDirectoryPath: "/Users/example/Downloads",
            totalBytes: totalBytes,
            supportsResume: true,
            segments: [DownloadSegment(id: 0, start: 0, end: totalBytes - 1, downloadedBytes: totalBytes)],
            status: .completed,
            createdAt: createdAt,
            startedAt: createdAt,
            completedAt: createdAt,
            order: order
        )
    }

    private static func identifier(_ string: String) -> UUID {
        guard let value = UUID(uuidString: string) else {
            preconditionFailure("Invalid hero fixture UUID: \(string)")
        }
        return value
    }

    private static func url(_ string: String) -> URL {
        guard let value = URL(string: string) else {
            preconditionFailure("Invalid hero fixture URL: \(string)")
        }
        return value
    }
}
#endif
