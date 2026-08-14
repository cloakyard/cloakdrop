import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadEngine

@Suite("Segment planner")
struct SegmentPlannerTests {

    /// Segments must tile [0, total-1] with no gaps or overlaps and the right total length.
    private func assertContiguous(_ segments: [DownloadSegment], total: Int64) {
        #expect(segments.first?.start == 0)
        #expect(segments.last?.end == total - 1)
        var expectedStart: Int64 = 0
        var sum: Int64 = 0
        for segment in segments {
            #expect(segment.start == expectedStart)
            #expect(segment.end >= segment.start)
            expectedStart = segment.end + 1
            sum += segment.length
        }
        #expect(sum == total)
    }

    @Test("Even split distributes the remainder to the leading segments")
    func evenSplit() {
        let segments = SegmentPlanner.plan(totalBytes: 1003, requestedSegments: 4, minimumSegmentSize: 1)
        #expect(segments.count == 4)
        assertContiguous(segments, total: 1003)
        // 1003 / 4 = 250 r3 → first three are 251, last is 250.
        #expect(segments.map(\.length) == [251, 251, 251, 250])
    }

    @Test("Segment count is capped so no segment is smaller than the minimum")
    func minimumSizeCap() {
        // 10 KB total, 1 MB minimum → only one segment is worthwhile.
        let segments = SegmentPlanner.plan(totalBytes: 10_000, requestedSegments: 8, minimumSegmentSize: 1_000_000)
        #expect(segments.count == 1)
        assertContiguous(segments, total: 10_000)
    }

    @Test("Requested count is honored when sizes allow")
    func honorsRequest() {
        let segments = SegmentPlanner.plan(totalBytes: 8_000_000, requestedSegments: 8, minimumSegmentSize: 1_000_000)
        #expect(segments.count == 8)
        assertContiguous(segments, total: 8_000_000)
    }

    @Test("Automatic connection count grows for very large files but respects every cap")
    func adaptiveRecommendation() {
        let mib: Int64 = 1024 * 1024
        #expect(SegmentPlanner.recommendedSegmentCount(
            totalBytes: 8 * mib,
            requestedSegments: nil,
            preferredSegments: 8,
            maximumSegments: 16,
            minimumSegmentSize: mib
        ) == 8)
        #expect(SegmentPlanner.recommendedSegmentCount(
            totalBytes: 512 * mib,
            requestedSegments: nil,
            preferredSegments: 8,
            maximumSegments: 16,
            minimumSegmentSize: mib
        ) == 16)
        // Only three minimum-size ranges fit, regardless of the preferred/maximum values.
        #expect(SegmentPlanner.recommendedSegmentCount(
            totalBytes: 3 * mib,
            requestedSegments: nil,
            preferredSegments: 8,
            maximumSegments: 16,
            minimumSegmentSize: mib
        ) == 3)
    }

    @Test("A manual connection override wins in automatic planning and is still safely clamped")
    func manualRecommendation() {
        let mib: Int64 = 1024 * 1024
        #expect(SegmentPlanner.recommendedSegmentCount(
            totalBytes: 512 * mib,
            requestedSegments: 3,
            preferredSegments: 8,
            maximumSegments: 16,
            minimumSegmentSize: mib
        ) == 3)
        #expect(SegmentPlanner.recommendedSegmentCount(
            totalBytes: 2 * mib,
            requestedSegments: 99,
            preferredSegments: 8,
            maximumSegments: 16,
            minimumSegmentSize: mib
        ) == 2)
    }

    @Test("Extreme minimum sizes never overflow adaptive or split math")
    func extremeMinimumIsSafe() {
        #expect(SegmentPlanner.recommendedSegmentCount(
            totalBytes: Int64.max,
            requestedSegments: nil,
            preferredSegments: 8,
            maximumSegments: 16,
            minimumSegmentSize: Int64.max
        ) == 1)
        let segment = DownloadSegment(id: 0, start: 0, end: 100)
        #expect(SegmentPlanner.split(segment, newSegmentID: 1, minimumSegmentSize: Int64.max) == nil)
    }

    @Test("Always at least one segment, even for tiny files")
    func atLeastOne() {
        let segments = SegmentPlanner.plan(totalBytes: 1, requestedSegments: 8, minimumSegmentSize: 1)
        #expect(segments.count == 1)
        #expect(segments[0].length == 1)
    }

    @Test("Splitting a stalled segment preserves bytes already written")
    func splitSegment() {
        var segment = DownloadSegment(id: 0, start: 0, end: 999, downloadedBytes: 200)
        let result = SegmentPlanner.split(segment, newSegmentID: 5, minimumSegmentSize: 1)
        let split = try! #require(result)
        // Original keeps its 200 downloaded bytes; the pair still covers [200, 999].
        #expect(split.updated.start == 0)
        #expect(split.updated.downloadedBytes == 200)
        #expect(split.new.id == 5)
        #expect(split.new.start == split.updated.end + 1)
        #expect(split.new.end == 999)
        #expect(split.updated.currentOffset <= split.new.start)
        segment.downloadedBytes = 999
        #expect(SegmentPlanner.split(segment, newSegmentID: 6, minimumSegmentSize: 1) == nil)
    }
}
