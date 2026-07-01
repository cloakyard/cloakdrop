import Foundation

/// User intent to create a download, before the engine has probed the server.
///
/// The add-download sheet builds one of these; the engine resolves it into a full
/// `Download` once it knows the file size and resume support.
public struct DownloadRequest: Sendable, Hashable {
    public var url: URL
    /// Override for the file name; when `nil`, the engine derives it from the URL/headers.
    public var suggestedFileName: String?
    public var destinationDirectoryPath: String
    public var destinationBookmark: Data?
    public var queueID: UUID
    /// Requested segment count; clamped to engine limits and server capability.
    public var segmentCount: Int?
    public var requestHeaders: [String: String]
    public var checksum: ChecksumExpectation?
    public var speedLimitBytesPerSecond: Int64?
    /// When set, the download is scheduled rather than started immediately.
    public var scheduledStart: Date?
    /// How often a scheduled download repeats.
    public var recurrence: ScheduleRecurrence
    /// Whether to begin transferring as soon as a queue slot is free.
    public var startImmediately: Bool
    /// HTTP authentication (Basic/Digest) for the source server, if required.
    public var username: String?
    public var password: String?
    /// Convenience capture fields that the engine folds into `requestHeaders` as the standard
    /// `Referer` / `Cookie` headers.
    public var referrer: String?
    public var cookies: String?

    public init(
        url: URL,
        suggestedFileName: String? = nil,
        destinationDirectoryPath: String,
        destinationBookmark: Data? = nil,
        queueID: UUID = DownloadQueue.defaultQueueID,
        segmentCount: Int? = nil,
        requestHeaders: [String: String] = [:],
        checksum: ChecksumExpectation? = nil,
        speedLimitBytesPerSecond: Int64? = nil,
        scheduledStart: Date? = nil,
        recurrence: ScheduleRecurrence = .none,
        startImmediately: Bool = true,
        username: String? = nil,
        password: String? = nil,
        referrer: String? = nil,
        cookies: String? = nil
    ) {
        self.url = url
        self.suggestedFileName = suggestedFileName
        self.destinationDirectoryPath = destinationDirectoryPath
        self.destinationBookmark = destinationBookmark
        self.queueID = queueID
        self.segmentCount = segmentCount
        self.requestHeaders = requestHeaders
        self.checksum = checksum
        self.speedLimitBytesPerSecond = speedLimitBytesPerSecond
        self.scheduledStart = scheduledStart
        self.recurrence = recurrence
        self.startImmediately = startImmediately
        self.username = username
        self.password = password
        self.referrer = referrer
        self.cookies = cookies
    }
}
