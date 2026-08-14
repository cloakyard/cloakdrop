import Foundation
import Testing
@testable import DownloadModels

@Suite("Catalog duplicate detection")
struct DuplicateDetectorTests {

    private func make(
        url: String,
        status: DownloadStatus = .completed,
        etag: String? = nil,
        size: Int64? = nil,
        name: String = "file.zip"
    ) -> Download {
        var download = Download(
            url: URL(string: url)!,
            fileName: name,
            destinationDirectoryPath: "/tmp",
            totalBytes: size,
            etag: etag
        )
        download.status = status
        return download
    }

    // MARK: Exact URL

    @Test("An identical source URL is a duplicate")
    func matchesSameURL() {
        let existing = make(url: "https://host.example/a.zip")
        let candidate = DuplicateCandidate(url: URL(string: "https://host.example/a.zip")!, fileName: "a.zip")
        let match = DuplicateDetector.findDuplicate(of: candidate, in: [existing])
        #expect(match?.reason == .sameURL)
        #expect(match?.existing.id == existing.id)
    }

    @Test("A canceled or failed download with the same URL is not a duplicate (nothing to have)")
    func ignoresCanceledAndFailedURL() {
        let canceled = make(url: "https://host.example/a.zip", status: .canceled)
        let failed = make(url: "https://host.example/a.zip", status: .failed(reason: "boom"))
        let candidate = DuplicateCandidate(url: URL(string: "https://host.example/a.zip")!, fileName: "a.zip")
        #expect(DuplicateDetector.findDuplicate(of: candidate, in: [canceled, failed]) == nil)
    }

    @Test("An in-flight download with the same URL is a duplicate (already getting it)")
    func matchesInFlightURL() {
        let downloading = make(url: "https://host.example/a.zip", status: .downloading)
        let candidate = DuplicateCandidate(url: URL(string: "https://host.example/a.zip")!, fileName: "a.zip")
        #expect(DuplicateDetector.findDuplicate(of: candidate, in: [downloading])?.reason == .sameURL)
    }

    // MARK: Same-origin ETag

    @Test("Same origin + same ETag is a duplicate even via a different URL")
    func matchesSameETag() {
        let existing = make(url: "https://cdn.example/file?sig=1", etag: "\"v7\"", size: 1000)
        let candidate = DuplicateCandidate(
            url: URL(string: "https://cdn.example/file?sig=2")!, etag: "\"v7\"", totalBytes: 1000, fileName: "file"
        )
        let match = DuplicateDetector.findDuplicate(of: candidate, in: [existing])
        #expect(match?.reason == .sameETag)
        #expect(match?.existing.id == existing.id)
    }

    @Test("Same ETag on a different host is not a duplicate (an ETag is per-origin)")
    func etagRequiresSameOriginHost() {
        let existing = make(url: "https://cdn-a.example/file", etag: "\"v7\"", size: 1000)
        let candidate = DuplicateCandidate(
            url: URL(string: "https://cdn-b.example/file")!, etag: "\"v7\"", totalBytes: 1000, fileName: "other"
        )
        #expect(DuplicateDetector.findDuplicate(of: candidate, in: [existing]) == nil)
    }

    @Test("Same host and ETag across schemes or non-default ports is not a duplicate")
    func etagRequiresSameOriginSchemeAndPort() {
        let existing = make(url: "https://cdn.example/file", etag: "\"v7\"", size: 1000)
        let httpCandidate = DuplicateCandidate(
            url: URL(string: "http://cdn.example/file?new")!, etag: "\"v7\"", totalBytes: 1000, fileName: "other"
        )
        let portCandidate = DuplicateCandidate(
            url: URL(string: "https://cdn.example:8443/file")!, etag: "\"v7\"", totalBytes: 1000, fileName: "other"
        )
        #expect(DuplicateDetector.findDuplicate(of: httpCandidate, in: [existing]) == nil)
        #expect(DuplicateDetector.findDuplicate(of: portCandidate, in: [existing]) == nil)
    }

    @Test("An explicit default port belongs to the same origin")
    func etagNormalizesDefaultPort() {
        let existing = make(url: "https://cdn.example/file?a", etag: "\"v7\"", size: 1000)
        let candidate = DuplicateCandidate(
            url: URL(string: "https://cdn.example:443/file?b")!, etag: "\"v7\"", totalBytes: 1000, fileName: "other"
        )
        #expect(DuplicateDetector.findDuplicate(of: candidate, in: [existing])?.reason == .sameETag)
    }

    @Test("Same ETag but a different known size is not a duplicate")
    func etagRejectsSizeMismatch() {
        let existing = make(url: "https://cdn.example/file?a", etag: "\"v7\"", size: 1000)
        let candidate = DuplicateCandidate(
            url: URL(string: "https://cdn.example/file?b")!, etag: "\"v7\"", totalBytes: 2000, fileName: "file"
        )
        #expect(DuplicateDetector.findDuplicate(of: candidate, in: [existing]) == nil)
    }

    @Test("An empty ETag never matches")
    func emptyETagIgnored() {
        let existing = make(url: "https://cdn.example/file?a", etag: "", size: 1000)
        let candidate = DuplicateCandidate(
            url: URL(string: "https://cdn.example/file?b")!, etag: "", totalBytes: 1000, fileName: "file"
        )
        #expect(DuplicateDetector.findDuplicate(of: candidate, in: [existing]) == nil)
    }

    // MARK: Same completed name + size

    @Test("A completed file with the same name and size is a duplicate")
    func matchesSameContent() {
        let existing = make(url: "https://host-a.example/a.zip", status: .completed, size: 500, name: "a.zip")
        let candidate = DuplicateCandidate(
            url: URL(string: "https://host-b.example/a.zip")!, totalBytes: 500, fileName: "a.zip"
        )
        #expect(DuplicateDetector.findDuplicate(of: candidate, in: [existing])?.reason == .sameContent)
    }

    @Test("Name + size only counts against a completed download (the file must be on disk)")
    func contentRequiresCompleted() {
        let inFlight = make(url: "https://host-a.example/a.zip", status: .downloading, size: 500, name: "a.zip")
        let candidate = DuplicateCandidate(
            url: URL(string: "https://host-b.example/a.zip")!, totalBytes: 500, fileName: "a.zip"
        )
        #expect(DuplicateDetector.findDuplicate(of: candidate, in: [inFlight]) == nil)
    }

    // MARK: Precedence & no-match

    @Test("Exact URL takes precedence over a weaker name+size match")
    func urlBeatsContent() {
        let byContent = make(url: "https://host.example/old.zip", status: .completed, size: 10, name: "f.zip")
        let byURL = make(url: "https://host.example/new.zip", status: .downloading, name: "f.zip")
        let candidate = DuplicateCandidate(
            url: URL(string: "https://host.example/new.zip")!, totalBytes: 10, fileName: "f.zip"
        )
        let match = DuplicateDetector.findDuplicate(of: candidate, in: [byContent, byURL])
        #expect(match?.reason == .sameURL)
        #expect(match?.existing.id == byURL.id)
    }

    @Test("A genuinely new download matches nothing")
    func noMatch() {
        let existing = make(url: "https://host.example/a.zip", size: 1, name: "a.zip")
        let candidate = DuplicateCandidate(
            url: URL(string: "https://host.example/z.zip")!, totalBytes: 999, fileName: "z.zip"
        )
        #expect(DuplicateDetector.findDuplicate(of: candidate, in: [existing]) == nil)
    }
}
