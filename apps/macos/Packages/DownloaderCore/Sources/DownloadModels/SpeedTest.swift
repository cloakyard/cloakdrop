import Foundation

/// Which service a manual speed test measures against.
///
/// The test is the one deliberate exception to "network access only to the URLs you download":
/// it runs only when the user starts it, and only against the provider chosen here.
public enum SpeedTestProvider: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    /// Cloudflare's anycast speed endpoints (`speed.cloudflare.com`). No account, no API key,
    /// and the nearest edge answers — the default.
    case cloudflare
    /// Ookla's Speedtest network, via its public HTTP server directory. Uses the closest
    /// recommended server; no SDK, account, or telemetry.
    case ookla

    public var id: String { rawValue }
}

/// The outcome of one completed speed test, shown in Settings and kept as the "last result".
public struct SpeedTestResult: Sendable, Codable, Hashable {
    public var provider: SpeedTestProvider
    /// Human-readable server identity ("Cloudflare", or the Ookla server's sponsor + city).
    public var serverName: String
    public var downloadBytesPerSecond: Double
    public var uploadBytesPerSecond: Double
    /// Median round-trip time with the link otherwise idle.
    public var idleLatencyMilliseconds: Double
    /// Median round-trip time sampled *while* the download phase saturated the link, or `nil`
    /// when no probe completed. The idle→loaded delta is the bufferbloat signal.
    public var loadedLatencyMilliseconds: Double?
    /// Mean variation between consecutive idle round trips.
    public var jitterMilliseconds: Double
    public var date: Date

    public init(
        provider: SpeedTestProvider,
        serverName: String,
        downloadBytesPerSecond: Double,
        uploadBytesPerSecond: Double,
        idleLatencyMilliseconds: Double,
        loadedLatencyMilliseconds: Double?,
        jitterMilliseconds: Double,
        date: Date
    ) {
        self.provider = provider
        self.serverName = serverName
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.idleLatencyMilliseconds = idleLatencyMilliseconds
        self.loadedLatencyMilliseconds = loadedLatencyMilliseconds
        self.jitterMilliseconds = jitterMilliseconds
        self.date = date
    }
}
