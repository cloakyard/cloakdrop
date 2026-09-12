import Foundation
import Testing
@testable import DownloadModels

@Suite("Aggregate download progress")
struct AggregateProgressTests {
    @Test func averagesDownloadsEquallyRegardlessOfSize() {
        let small = download(total: 100, completed: 20)
        let large = download(total: 10_000, completed: 8_000)
        #expect(aggregate([small, large]) == 0.5)
    }

    @Test func usesLiveBytesAndLiveTotalInsteadOfPersistedState() {
        let first = download(total: nil)
        let second = download(total: 1_000, completed: 100)
        let live = [tick(first, bytes: 200, total: 1_000), tick(second, bytes: 1_600, total: 2_000)]
        #expect(aggregate([first, second], live: live) == 0.5)
        #expect(aggregate([first, second], live: [tick(first, bytes: 600, total: 1_000), live[1]]) == 0.7)
    }

    @Test func combinesMediaSegmentsWithFileProgress() {
        let media = download(total: nil)
        let file = download(total: 100, completed: 20)
        let live = DownloadProgress(
            id: media.id, downloadedBytes: 9_000_000, totalBytes: nil,
            bytesPerSecond: 100, completedSegments: 8, totalSegments: 10
        )
        #expect(aggregate([media, file], live: [live]) == 0.5)
    }

    @Test func unknownSizeDoesNotMasqueradeAsComplete() {
        let unknown = download(total: nil)
        let known = download(total: 100, completed: 50)
        let live = tick(unknown, bytes: 9_000, total: nil)
        #expect(aggregate([unknown], live: [live]) == nil)
        #expect(aggregate([known, unknown], live: [live]) == nil)
        #expect(aggregate([download(total: 0)]) == nil)
    }

    @Test func indeterminateLiveStateDoesNotReviveAnOldTotal() {
        let item = download(total: 100, completed: 50)
        #expect(aggregate([item], live: [tick(item, bytes: 10, total: nil)]) == nil)
    }

    @Test func excludesInactiveDownloadsAndTheirStaleTicks() {
        let active = download(total: 100, completed: 20)
        let statuses: [DownloadStatus] = [.queued, .paused, .completed, .failed(reason: "Fixture"), .scheduled, .canceled]
        let inactive = statuses.map { download(total: 100, completed: 90, status: $0) }
        let live = inactive.map { tick($0, bytes: 100, total: 100) }
        #expect(aggregate([active] + inactive, live: live) == 0.2)
        #expect(aggregate(inactive, live: live) == nil)
        #expect(aggregate([]) == nil)
    }

    @Test func clampsInvalidCountsWithoutSummingLargeByteTotals() {
        let first = download(total: Int64.max)
        let second = download(total: Int64.max)
        #expect(aggregate([first, second], live: [
            tick(first, bytes: Int64.max, total: Int64.max), tick(second, bytes: Int64.max, total: Int64.max)
        ]) == 1)
        #expect(aggregate([first], live: [tick(first, bytes: -10, total: 100)]) == 0)
        #expect(aggregate([first], live: [tick(first, bytes: 200, total: 100)]) == 1)
    }

    private func aggregate(_ downloads: [Download], live: [DownloadProgress] = []) -> Double? {
        let snapshots = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        return DownloadProgress.aggregateFraction(downloads: downloads) { snapshots[$0] }
    }

    private func tick(_ item: Download, bytes: Int64, total: Int64?) -> DownloadProgress {
        DownloadProgress(id: item.id, downloadedBytes: bytes, totalBytes: total, bytesPerSecond: 100)
    }

    private func download(total: Int64?, completed: Int64 = 0, status: DownloadStatus = .downloading) -> Download {
        Download(
            url: URL(string: "https://example.invalid/fixture.bin")!, fileName: "fixture.bin",
            destinationDirectoryPath: "/tmp", totalBytes: total,
            segments: [DownloadSegment(id: 0, start: 0, end: max(0, (total ?? 1) - 1), downloadedBytes: completed)],
            status: status
        )
    }
}
