import Foundation
import Testing
@testable import DownloadModels

@Suite("Segment math")
struct SegmentTests {
    @Test("Length, remaining, and offset are derived correctly")
    func segmentArithmetic() {
        var seg = DownloadSegment(id: 0, start: 100, end: 199)
        #expect(seg.length == 100)
        #expect(seg.remainingBytes == 100)
        #expect(seg.currentOffset == 100)
        #expect(!seg.isComplete)

        seg.downloadedBytes = 40
        #expect(seg.remainingBytes == 60)
        #expect(seg.currentOffset == 140)
        #expect(!seg.isComplete)

        seg.downloadedBytes = 100
        #expect(seg.remainingBytes == 0)
        #expect(seg.isComplete)
    }
}

@Suite("File categorization")
struct FileCategoryTests {
    @Test("Extensions map to the expected category", arguments: [
        ("movie.mp4", FileCategory.video),
        ("song.FLAC", .audio),
        ("report.pdf", .document),
        ("bundle.tar.gz", .archive),
        ("Tool.dmg", .archive),
        ("installer.pkg", .program),
        ("photo.HEIC", .image),
        ("mystery", .other),
        ("data.unknownext", .other)
    ])
    func classify(name: String, expected: FileCategory) {
        #expect(FileCategory.classify(fileName: name) == expected)
    }
}

@Suite("Download derived values")
struct DownloadTests {
    private func makeDownload(total: Int64?, segments: [DownloadSegment]) -> Download {
        Download(
            url: URL(string: "https://example.com/file.zip")!,
            fileName: "file.zip",
            destinationDirectoryPath: "/tmp",
            totalBytes: total,
            segments: segments
        )
    }

    @Test("downloadedBytes sums segments and fraction is bounded")
    func aggregation() {
        let d = makeDownload(
            total: 1000,
            segments: [
                DownloadSegment(id: 0, start: 0, end: 499, downloadedBytes: 250),
                DownloadSegment(id: 1, start: 500, end: 999, downloadedBytes: 500)
            ]
        )
        #expect(d.downloadedBytes == 750)
        #expect(d.fractionCompleted == 0.75)
        #expect(!d.allSegmentsComplete)
    }

    @Test("fractionCompleted is nil when total size is unknown")
    func unknownTotal() {
        let d = makeDownload(total: nil, segments: [DownloadSegment(id: 0, start: 0, end: 99, downloadedBytes: 50)])
        #expect(d.fractionCompleted == nil)
    }

    @Test("Category is auto-derived from the file name")
    func autoCategory() {
        let d = makeDownload(total: 10, segments: [])
        #expect(d.category == .archive)
    }

    @Test("Older persisted downloads decode with automatic connection selection")
    func legacyDecodeDefaultsToAutomaticConnections() throws {
        var download = makeDownload(total: 1_000, segments: [])
        download.requestedSegmentCount = 3
        let encoded = try JSONEncoder().encode(download)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "requestedSegmentCount")

        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Download.self, from: legacy)
        #expect(decoded.requestedSegmentCount == nil)
    }
}

@Suite("Checksum expectation")
struct ChecksumTests {
    @Test("Well-formed digests validate; malformed ones do not")
    func wellFormed() {
        let good = ChecksumExpectation(algorithm: .sha256, expectedHex: String(repeating: "a", count: 64))
        #expect(good.isWellFormed)

        let trimmedUpper = ChecksumExpectation(algorithm: .md5, expectedHex: "  " + String(repeating: "F", count: 32) + "\n")
        #expect(trimmedUpper.isWellFormed)
        #expect(trimmedUpper.expectedHex == String(repeating: "f", count: 32))

        let tooShort = ChecksumExpectation(algorithm: .sha1, expectedHex: "abc")
        #expect(!tooShort.isWellFormed)

        let nonHex = ChecksumExpectation(algorithm: .md5, expectedHex: String(repeating: "z", count: 32))
        #expect(!nonHex.isWellFormed)
    }

    @Test("An all-zero digest is well-formed but not usable (placeholder, not a real checksum)")
    func allZeroPlaceholderIsUnusable() {
        let zeros = ChecksumExpectation(algorithm: .sha256, expectedHex: String(repeating: "0", count: 64))
        #expect(zeros.isWellFormed)   // 64 valid hex chars
        #expect(!zeros.isUsable)      // …but all-zero means "none"

        let real = ChecksumExpectation(algorithm: .sha256, expectedHex: String(repeating: "0", count: 63) + "1")
        #expect(real.isUsable)        // a single non-zero digit makes it a real digest
    }
}

@Suite("Engine settings decoding")
struct EngineSettingsCodableTests {
    /// A settings blob written by an older build lacks fields added later (here: `autoCategorize`,
    /// `proxy`, `postCompletionAction`). The tolerant decoder must fill those with defaults
    /// while preserving every value that *is* present — otherwise launch bricks on upgrade.
    @Test("Missing keys fall back to defaults; present keys are preserved")
    func tolerantDecodeOfLegacyPayload() throws {
        let legacy = #"""
        {
            "defaultSegmentCount": 12,
            "maxSegmentCount": 24,
            "maxRetryAttempts": 9,
            "retryBaseDelaySeconds": 2,
            "retryMaxDelaySeconds": 45,
            "minimumSegmentSizeBytes": 2097152,
            "verifyChecksumsAutomatically": false,
            "globalSpeedLimitBytesPerSecond": 5000000
        }
        """#
        let decoded = try JSONDecoder().decode(EngineSettings.self, from: Data(legacy.utf8))

        // Present values survive.
        #expect(decoded.defaultSegmentCount == 12)
        #expect(decoded.maxSegmentCount == 24)
        #expect(decoded.maxRetryAttempts == 9)
        #expect(decoded.verifyChecksumsAutomatically == false)
        #expect(decoded.globalSpeedLimitBytesPerSecond == 5_000_000)
        // Absent values default rather than throwing.
        #expect(decoded.autoCategorize == EngineSettings.default.autoCategorize)
        #expect(decoded.resolvedProxy.mode == .system)
        #expect(decoded.resolvedPostAction == .none)
    }

    @Test("Round-trips preserve every field, including newer optional ones")
    func roundTrip() throws {
        var settings = EngineSettings.default
        settings.autoCategorize = true
        settings.proxy = ProxyConfiguration(mode: .manual, type: .socks5, host: "h", port: 1080)
        settings.postCompletionAction = .quit
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(EngineSettings.self, from: data) == settings)
    }
}

@Suite("Smart filters")
struct SmartFilterTests {
    private func download(_ status: DownloadStatus) -> Download {
        var d = Download(url: URL(string: "https://e.com/a")!, fileName: "a", destinationDirectoryPath: "/tmp")
        d.status = status
        return d
    }

    @Test("Filters partition downloads by status")
    func partition() {
        #expect(SmartFilter.all.matches(download(.completed)))
        #expect(SmartFilter.downloading.matches(download(.paused)))
        #expect(SmartFilter.downloading.matches(download(.downloading)))
        #expect(!SmartFilter.downloading.matches(download(.completed)))
        #expect(SmartFilter.completed.matches(download(.completed)))
        #expect(SmartFilter.failed.matches(download(.failed(reason: "x"))))
        #expect(SmartFilter.scheduled.matches(download(.scheduled)))
    }
}

@Suite("Resolution quality label")
struct ResolutionLabelTests {
    // Expected tiers mirror yt-dlp's own ladder labels (verified against a real 2:1 YouTube video).
    @Test("qualityHeight matches the streaming ladder across aspect ratios", arguments: [
        (1920, 1080, 1080),   // 16:9 1080p
        (3840, 2160, 2160),   // 16:9 4K
        (2560, 1440, 1440),   // 16:9 1440p
        (1080, 1920, 1080),   // portrait/Shorts → 1080p, not 1920p
        (720, 1280, 720),     // portrait → 720p
        (3840, 1920, 2160),   // cinematic 2:1 → 2160p (as YouTube labels it), not 1920p
        (1920, 960, 1080),    // cinematic 2:1 → 1080p
        (1280, 640, 720),     // cinematic 2:1 → 720p
        (426, 214, 240),      // cinematic 2:1 → 240p (rounds up)
        (640, 480, 480),      // 4:3 → 480p
        (1440, 1080, 1080),   // 4:3 → 1080p
        (720, 720, 720)       // square → 720p
    ])
    func qualityHeight(width: Int, height: Int, expected: Int) {
        #expect(MediaResolution(width: width, height: height).qualityHeight == expected)
    }
}
