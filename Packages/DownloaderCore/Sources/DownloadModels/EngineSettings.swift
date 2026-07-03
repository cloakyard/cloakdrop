import Foundation

/// Engine-wide tunables. These are persisted and editable from Settings.
///
/// Defaults match the brief: 8 segments, sensible retry/backoff, no global speed cap.
public struct EngineSettings: Sendable, Hashable, Codable {
    /// Default number of parallel segments per download when the server supports Range.
    public var defaultSegmentCount: Int
    /// Hard cap on segments per download, regardless of per-download requests.
    public var maxSegmentCount: Int
    /// Global download speed limit in bytes/sec across all downloads. `nil` means unlimited.
    public var globalSpeedLimitBytesPerSecond: Int64?
    /// Optional time-of-day override for the global limit (e.g. throttle during work hours, unlimited
    /// overnight). `nil`/disabled means the global limit above applies around the clock.
    public var bandwidthSchedule: BandwidthSchedule?
    /// Maximum automatic retry attempts for a transient failure before giving up.
    public var maxRetryAttempts: Int
    /// Base delay (seconds) for exponential backoff between retries.
    public var retryBaseDelaySeconds: Double
    /// Ceiling (seconds) for a single backoff delay.
    public var retryMaxDelaySeconds: Double
    /// Smallest segment size (bytes) worth splitting; files below this stay single-stream.
    public var minimumSegmentSizeBytes: Int64
    /// Whether to verify provided checksums automatically on completion.
    public var verifyChecksumsAutomatically: Bool
    /// When a download finishes without a supplied checksum, whether to look for a sibling checksum
    /// file next to it on the same server (`file.zip` → `file.zip.sha256`/`.sha1`/`.md5`) and verify
    /// against it. Same-origin only, and additionally gated by `verifyChecksumsAutomatically`.
    public var autoDiscoverChecksums: Bool
    /// When a download of an installable type (`.app`/`.dmg`) finishes, whether to assess its code
    /// signature on-device (via the Security framework) and record the result — signed & valid,
    /// invalid, or unsigned — so the UI can show a trust badge. Fully local; no network egress.
    public var assessSignatures: Bool
    /// When true, completed files are filed into a per-type subfolder (Video, Documents, …)
    /// of their destination directory.
    public var autoCategorize: Bool
    /// When true, completed files are stamped with the `com.apple.quarantine` flag (like a browser
    /// download) so Gatekeeper vets them on first open. On by default; fully local.
    public var applyQuarantine: Bool
    /// When true, a completed `.zip` is automatically extracted into a sibling folder (native
    /// extraction — no external tool). Off by default.
    public var autoExtractArchives: Bool
    /// When true, a verified-download provenance receipt (source, mirrors, SHA-256, checksum &
    /// signature verdicts, one trust verdict) is assembled on completion. On by default; fully local.
    public var generateProvenanceReceipts: Bool
    /// On launch, whether downloads that were mid-transfer when the app last quit resume
    /// automatically. When false they come back paused, so the user starts them when they choose.
    public var resumeDownloadsOnLaunch: Bool
    /// How the engine routes connections. `nil` is treated as `.system` for backward
    /// compatibility with settings saved before proxies existed.
    public var proxy: ProxyConfiguration?
    /// What to do once every download finishes. `nil` is treated as `.none`.
    public var postCompletionAction: SchedulerPostAction?
    /// The Shortcut to run when `postCompletionAction == .runShortcut`. Matched by name against the
    /// user's Shortcuts library via the `shortcuts://run-shortcut` URL scheme.
    public var postCompletionShortcutName: String?

    public init(
        defaultSegmentCount: Int = 8,
        maxSegmentCount: Int = 16,
        globalSpeedLimitBytesPerSecond: Int64? = nil,
        bandwidthSchedule: BandwidthSchedule? = nil,
        maxRetryAttempts: Int = 5,
        retryBaseDelaySeconds: Double = 1.0,
        retryMaxDelaySeconds: Double = 30.0,
        minimumSegmentSizeBytes: Int64 = 1 * 1024 * 1024,
        verifyChecksumsAutomatically: Bool = true,
        autoDiscoverChecksums: Bool = true,
        assessSignatures: Bool = true,
        autoCategorize: Bool = false,
        applyQuarantine: Bool = true,
        autoExtractArchives: Bool = false,
        generateProvenanceReceipts: Bool = true,
        resumeDownloadsOnLaunch: Bool = true,
        proxy: ProxyConfiguration? = nil,
        postCompletionAction: SchedulerPostAction? = nil,
        postCompletionShortcutName: String? = nil
    ) {
        self.defaultSegmentCount = max(1, defaultSegmentCount)
        self.maxSegmentCount = max(1, maxSegmentCount)
        self.globalSpeedLimitBytesPerSecond = globalSpeedLimitBytesPerSecond
        self.bandwidthSchedule = bandwidthSchedule
        self.maxRetryAttempts = max(0, maxRetryAttempts)
        self.retryBaseDelaySeconds = retryBaseDelaySeconds
        self.retryMaxDelaySeconds = retryMaxDelaySeconds
        self.minimumSegmentSizeBytes = max(0, minimumSegmentSizeBytes)
        self.verifyChecksumsAutomatically = verifyChecksumsAutomatically
        self.autoDiscoverChecksums = autoDiscoverChecksums
        self.assessSignatures = assessSignatures
        self.autoCategorize = autoCategorize
        self.applyQuarantine = applyQuarantine
        self.autoExtractArchives = autoExtractArchives
        self.generateProvenanceReceipts = generateProvenanceReceipts
        self.resumeDownloadsOnLaunch = resumeDownloadsOnLaunch
        self.proxy = proxy
        self.postCompletionAction = postCompletionAction
        self.postCompletionShortcutName = postCompletionShortcutName
    }

    /// The effective proxy, treating an absent value as "use the system proxy".
    public var resolvedProxy: ProxyConfiguration { proxy ?? .system }
    /// The effective post-completion action, treating an absent value as "do nothing".
    public var resolvedPostAction: SchedulerPostAction { postCompletionAction ?? .none }

    public static let `default` = EngineSettings()

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case defaultSegmentCount, maxSegmentCount, globalSpeedLimitBytesPerSecond, bandwidthSchedule
        case maxRetryAttempts, retryBaseDelaySeconds, retryMaxDelaySeconds
        case minimumSegmentSizeBytes, verifyChecksumsAutomatically, autoDiscoverChecksums, autoCategorize
        case applyQuarantine, autoExtractArchives, generateProvenanceReceipts
        case assessSignatures
        case resumeDownloadsOnLaunch
        case proxy, postCompletionAction, postCompletionShortcutName
    }

    /// Tolerant decoder: any key absent from the stored payload falls back to its default.
    ///
    /// Settings are persisted as a single JSON blob that grows as the app evolves. Swift's
    /// *synthesized* decoder throws `keyNotFound` for a missing non-optional key (it ignores
    /// init defaults), so adding a field would otherwise break decode of every settings row
    /// written by an older build — bricking launch on upgrade. Decoding each field with
    /// `decodeIfPresent ?? default` keeps old blobs (and future additions) forward-compatible
    /// while preserving every value that *is* present.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = EngineSettings.default
        func value<T: Decodable>(_ key: CodingKeys, _ defaultValue: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? defaultValue
        }
        self.init(
            defaultSegmentCount: try value(.defaultSegmentCount, fallback.defaultSegmentCount),
            maxSegmentCount: try value(.maxSegmentCount, fallback.maxSegmentCount),
            globalSpeedLimitBytesPerSecond: try container.decodeIfPresent(Int64.self, forKey: .globalSpeedLimitBytesPerSecond),
            bandwidthSchedule: try container.decodeIfPresent(BandwidthSchedule.self, forKey: .bandwidthSchedule),
            maxRetryAttempts: try value(.maxRetryAttempts, fallback.maxRetryAttempts),
            retryBaseDelaySeconds: try value(.retryBaseDelaySeconds, fallback.retryBaseDelaySeconds),
            retryMaxDelaySeconds: try value(.retryMaxDelaySeconds, fallback.retryMaxDelaySeconds),
            minimumSegmentSizeBytes: try value(.minimumSegmentSizeBytes, fallback.minimumSegmentSizeBytes),
            verifyChecksumsAutomatically: try value(.verifyChecksumsAutomatically, fallback.verifyChecksumsAutomatically),
            autoDiscoverChecksums: try value(.autoDiscoverChecksums, fallback.autoDiscoverChecksums),
            assessSignatures: try value(.assessSignatures, fallback.assessSignatures),
            autoCategorize: try value(.autoCategorize, fallback.autoCategorize),
            applyQuarantine: try value(.applyQuarantine, fallback.applyQuarantine),
            autoExtractArchives: try value(.autoExtractArchives, fallback.autoExtractArchives),
            generateProvenanceReceipts: try value(.generateProvenanceReceipts, fallback.generateProvenanceReceipts),
            resumeDownloadsOnLaunch: try value(.resumeDownloadsOnLaunch, fallback.resumeDownloadsOnLaunch),
            proxy: try container.decodeIfPresent(ProxyConfiguration.self, forKey: .proxy),
            postCompletionAction: try container.decodeIfPresent(SchedulerPostAction.self, forKey: .postCompletionAction),
            postCompletionShortcutName: try container.decodeIfPresent(String.self, forKey: .postCompletionShortcutName)
        )
    }
}
