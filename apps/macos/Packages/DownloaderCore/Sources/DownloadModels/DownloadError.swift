import Foundation

/// Errors surfaced by the download engine. Each case maps to a clear user-facing message.
public enum DownloadError: Error, Sendable, Hashable, Codable {
    /// The URL was not a valid, supported HTTP/HTTPS URL.
    case invalidURL(String)
    /// The server responded with a non-success HTTP status.
    case httpStatus(code: Int)
    /// The destination location could not be written to.
    case fileSystem(reason: String)
    /// The destination disk doesn't have enough free space for the remaining bytes.
    case insufficientDiskSpace(needed: Int64, available: Int64)
    /// The network connection was lost.
    case networkLost
    /// A transfer exceeded its retry budget.
    case retriesExhausted(lastReason: String)
    /// The finished file's checksum did not match the expected value.
    case checksumMismatch(algorithm: ChecksumAlgorithm, expected: String, actual: String)
    /// The transfer was canceled.
    case canceled
    /// An otherwise-unclassified underlying error.
    case underlying(reason: String)

    /// A concise, user-presentable description suitable for the UI and notifications.
    public var userMessage: String {
        switch self {
        case .invalidURL(let url):
            return "Not a valid download URL: \(url)"
        case .httpStatus(let code):
            return "Server returned HTTP \(code)."
        case .fileSystem(let reason):
            return "Could not write the file: \(reason)"
        case .insufficientDiskSpace(let needed, let available):
            let formatter = ByteCountFormatter()
            return "Not enough free space: needs \(formatter.string(fromByteCount: needed)), "
                + "but only \(formatter.string(fromByteCount: available)) is available."
        case .networkLost:
            return "Network connection lost."
        case .retriesExhausted(let lastReason):
            return "Gave up after repeated failures: \(lastReason)"
        case .checksumMismatch(let algorithm, _, _):
            return "\(algorithm.displayName) checksum did not match. The file may be corrupt."
        case .canceled:
            return "Download canceled."
        case .underlying(let reason):
            return reason
        }
    }
}
