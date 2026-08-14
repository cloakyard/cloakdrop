import Foundation

/// The complete persisted record of a single download.
///
/// This is a value type: the engine mutates copies and writes them back to the store,
/// and the UI renders snapshots. Ephemeral metrics (instantaneous speed, ETA) live in
/// `DownloadProgress`, not here, so they never bloat persistence.
public struct Download: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    /// The source URL being downloaded.
    public var url: URL
    /// Additional mirror URLs for the *same* content (from a Metalink), strongest-first and
    /// excluding `url`. The segment workers spread across these for parallel throughput and fail
    /// over between them on a transient error. Optional so older persisted records still decode.
    public var mirrors: [URL]?
    /// The final file name on disk (including extension).
    public var fileName: String
    /// Absolute path of the destination directory chosen by the user.
    public var destinationDirectoryPath: String
    /// Security-scoped bookmark for the destination directory (App Sandbox). May be nil for non-sandboxed builds.
    public var destinationBookmark: Data?

    /// Total file size in bytes, or `nil` if the server did not report it.
    public var totalBytes: Int64?
    /// Whether the server advertised `Accept-Ranges: bytes` (required for multi-segment & resume).
    public var supportsResume: Bool
    /// The resource's `ETag` as reported by the server at probe time, if any. A content-derived
    /// tag used to recognize a re-added download as a duplicate of one already in the catalog.
    public var etag: String?
    /// The segments composing this download. A single element means single-stream.
    public var segments: [DownloadSegment]
    /// A user-selected connection count for this download. `nil` means the engine chooses
    /// automatically from the resource size and current connection limits. Persisting the choice
    /// is essential: planning may happen after a scheduled start or a full app relaunch.
    public var requestedSegmentCount: Int?

    public var status: DownloadStatus
    public var category: FileCategory
    public var queueID: UUID

    /// Optional per-download additional request headers (auth, referrer, cookies, etc.).
    public var requestHeaders: [String: String]
    /// Optional per-download speed limit in bytes/sec; `nil` uses the global setting.
    public var speedLimitBytesPerSecond: Int64?

    /// Peak transfer rate observed over the download (bytes/sec), for the per-item stats summary.
    /// `nil` until bytes have flowed. Optional so older persisted records still decode.
    public var peakBytesPerSecond: Double?
    /// Accumulated *active* transfer time in seconds — idle/paused gaps excluded — the denominator
    /// for the average-speed stat. `nil` until bytes have flowed.
    public var activeSeconds: Double?

    /// HTTP authentication for the source server (Basic/Digest), if required. Persisted with
    /// the rest of the local, user-deletable download state.
    public var username: String?
    public var password: String?

    /// Expected checksum to verify against on completion, if any.
    public var checksum: ChecksumExpectation?
    /// Whether the completed file passed checksum verification (`nil` if not yet verified).
    public var checksumVerified: Bool?
    /// The code-signature assessment of the finished file, for installable types (`.app`/`.dmg`).
    /// `nil` when not assessed (unsupported type, disabled, or not yet complete).
    public var signature: SignatureAssessment?
    /// The verified-download provenance record, assembled on completion. `nil` until the download
    /// finishes.
    public var provenance: ProvenanceReceipt?

    /// When the user added this download.
    public var createdAt: Date
    /// When the transfer first began moving bytes.
    public var startedAt: Date?
    /// When the transfer completed successfully.
    public var completedAt: Date?
    /// For scheduled downloads, the time at which to start.
    public var scheduledStart: Date?
    /// How often a scheduled download repeats (one-shot when `nil`/`.none`).
    public var recurrence: ScheduleRecurrence?
    /// Explicit ordering within its queue (drag-to-reorder).
    public var order: Int

    // MARK: Media (HLS/DASH) — present only for a media grab (Phase 4)

    /// The resolved segment plan when this is a media download; `nil` for a normal file download.
    /// Its presence switches the engine onto the media transfer path.
    public var mediaPlan: MediaPlan?
    /// Persisted media progress: how many segments have finished (drives the fraction, since the
    /// total byte size usually isn't known up front) and the bytes written so far (for display).
    public var mediaCompletedSegments: Int
    public var mediaDownloadedBytes: Int64

    public init(
        id: UUID = UUID(),
        url: URL,
        mirrors: [URL]? = nil,
        fileName: String,
        destinationDirectoryPath: String,
        destinationBookmark: Data? = nil,
        totalBytes: Int64? = nil,
        supportsResume: Bool = false,
        etag: String? = nil,
        segments: [DownloadSegment] = [],
        requestedSegmentCount: Int? = nil,
        status: DownloadStatus = .queued,
        category: FileCategory? = nil,
        queueID: UUID = DownloadQueue.defaultQueueID,
        requestHeaders: [String: String] = [:],
        speedLimitBytesPerSecond: Int64? = nil,
        peakBytesPerSecond: Double? = nil,
        activeSeconds: Double? = nil,
        username: String? = nil,
        password: String? = nil,
        checksum: ChecksumExpectation? = nil,
        checksumVerified: Bool? = nil,
        signature: SignatureAssessment? = nil,
        provenance: ProvenanceReceipt? = nil,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        scheduledStart: Date? = nil,
        recurrence: ScheduleRecurrence? = nil,
        order: Int = 0,
        mediaPlan: MediaPlan? = nil,
        mediaCompletedSegments: Int = 0,
        mediaDownloadedBytes: Int64 = 0
    ) {
        self.id = id
        self.url = url
        self.mirrors = mirrors
        self.fileName = fileName
        self.destinationDirectoryPath = destinationDirectoryPath
        self.destinationBookmark = destinationBookmark
        self.totalBytes = totalBytes
        self.supportsResume = supportsResume
        self.etag = etag
        self.segments = segments
        self.requestedSegmentCount = requestedSegmentCount
        self.status = status
        self.category = category ?? FileCategory.classify(fileName: fileName)
        self.queueID = queueID
        self.requestHeaders = requestHeaders
        self.speedLimitBytesPerSecond = speedLimitBytesPerSecond
        self.peakBytesPerSecond = peakBytesPerSecond
        self.activeSeconds = activeSeconds
        self.username = username
        self.password = password
        self.checksum = checksum
        self.checksumVerified = checksumVerified
        self.signature = signature
        self.provenance = provenance
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.scheduledStart = scheduledStart
        self.recurrence = recurrence
        self.order = order
        self.mediaPlan = mediaPlan
        self.mediaCompletedSegments = mediaCompletedSegments
        self.mediaDownloadedBytes = mediaDownloadedBytes
    }

    // MARK: Derived values

    /// Whether this is a media (HLS/DASH) grab rather than a normal file download.
    public var isMedia: Bool { mediaPlan != nil }

    /// Every source to pull bytes from, best-first and de-duplicated: the primary `url` followed by
    /// any Metalink `mirrors`. The segment workers round-robin across this list (each segment starts
    /// on a different entry for parallel throughput) and advance to the next on a transient failure.
    public var transferSources: [URL] {
        var seen = Set<URL>()
        return ([url] + (mirrors ?? [])).filter { seen.insert($0).inserted }
    }

    /// Absolute destination path of the finished file.
    public var destinationFilePath: String {
        (destinationDirectoryPath as NSString).appendingPathComponent(fileName)
    }

    /// Path of the in-progress part file the engine writes into before finalizing (file downloads).
    public var partFilePath: String { destinationFilePath + ".cdpart" }

    /// Directory of the in-progress media segment files (media downloads write one file per segment).
    public var mediaPartDirectoryPath: String { destinationFilePath + ".cdparts" }

    /// Bytes downloaded so far: the running media byte count for a media grab, else the sum across
    /// byte-range segments.
    public var downloadedBytes: Int64 {
        isMedia ? mediaDownloadedBytes : segments.reduce(0) { $0 + $1.downloadedBytes }
    }

    /// Average transfer rate (bytes/sec) over the download's active time, or `nil` if not yet
    /// measurable. The companion to `peakBytesPerSecond` for the per-item stats summary.
    public var averageBytesPerSecond: Double? {
        guard let activeSeconds, activeSeconds > 0 else { return nil }
        return Double(downloadedBytes) / activeSeconds
    }

    /// Fraction complete in `0...1`, or `nil` when it can't be determined. For media it's the share
    /// of segments finished (the total byte size usually isn't known up front); for a file download
    /// it's bytes over the total.
    public var fractionCompleted: Double? {
        if let plan = mediaPlan {
            guard plan.totalSegments > 0 else { return nil }
            return min(1.0, Double(mediaCompletedSegments) / Double(plan.totalSegments))
        }
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1.0, Double(downloadedBytes) / Double(totalBytes))
    }

    /// Whether every segment has finished transferring.
    public var allSegmentsComplete: Bool {
        if let plan = mediaPlan { return mediaCompletedSegments >= plan.totalSegments }
        return !segments.isEmpty && segments.allSatisfy(\.isComplete)
    }
}
