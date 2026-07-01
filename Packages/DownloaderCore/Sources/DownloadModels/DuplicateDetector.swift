import Foundation

/// A prospective download to test against the catalog *before* committing it, so the app can warn
/// "you already have this" instead of silently creating a second copy. Filled from the add request
/// plus (when available) a `LinkPreview`, which contributes the content signals — `etag` and size.
public struct DuplicateCandidate: Sendable, Hashable {
    public var url: URL
    /// The resource's `ETag` from a pre-flight probe, if one was made.
    public var etag: String?
    /// The resource's size from a pre-flight probe, if known.
    public var totalBytes: Int64?
    /// The file name the download would be saved as.
    public var fileName: String

    public init(url: URL, etag: String? = nil, totalBytes: Int64? = nil, fileName: String) {
        self.url = url
        self.etag = etag
        self.totalBytes = totalBytes
        self.fileName = fileName
    }

    /// Build a candidate from an add request, enriched with a pre-flight preview when one exists.
    public init(request url: URL, fileName: String, preview: LinkPreview?) {
        self.url = url
        self.fileName = fileName
        self.etag = preview?.etag
        self.totalBytes = preview?.totalBytes
    }
}

/// Why a prospective download is considered a duplicate of one already in the catalog — ordered
/// strongest evidence first. Drives the wording of the confirmation the user sees.
public enum DuplicateReason: String, Sendable, Hashable, Codable {
    /// Identical source URL — unambiguously the same download.
    case sameURL
    /// Same server and same `ETag`: the server vouches the bytes are identical, even via a
    /// different URL (e.g. a signed/mirror link for the same file).
    case sameETag
    /// A completed download with the same file name and size already sits on disk.
    case sameContent
}

/// The existing download a candidate matched, and why.
public struct DuplicateMatch: Sendable, Hashable {
    public var existing: Download
    public var reason: DuplicateReason

    public init(existing: Download, reason: DuplicateReason) {
        self.existing = existing
        self.reason = reason
    }
}

/// Content-addressed duplicate detection: decides whether a prospective download already exists in
/// the catalog, by exact URL, by same-origin `ETag`, or by an already-completed file of the same
/// name and size. Pure and I/O-free — it reasons purely over `Download` values, so it's exhaustively
/// unit-tested and runs on the main actor without touching the network or disk.
public enum DuplicateDetector {

    /// The strongest duplicate match for `candidate` among `downloads`, or `nil` if it's genuinely
    /// new. Checks in order of confidence: exact URL → same-origin ETag → same completed name+size.
    public static func findDuplicate(of candidate: DuplicateCandidate, in downloads: [Download]) -> DuplicateMatch? {
        // 1) Exact source URL — the same link, unambiguously. (Matches the app's long-standing guard.)
        if let existing = downloads.first(where: { isPresent($0) && $0.url == candidate.url }) {
            return DuplicateMatch(existing: existing, reason: .sameURL)
        }

        // 2) Same origin + same ETag — content-identical per the server, even via a different URL.
        //    Constrained to the same host (an ETag is only meaningful within its origin) and, when
        //    both sizes are known, a matching size, to keep the signal tight.
        if let etag = candidate.etag, !etag.isEmpty, let host = normalizedHost(candidate.url) {
            if let existing = downloads.first(where: {
                isPresent($0)
                    && $0.etag == etag
                    && normalizedHost($0.url) == host
                    && sizesCompatible(candidate.totalBytes, $0.totalBytes)
            }) {
                return DuplicateMatch(existing: existing, reason: .sameETag)
            }
        }

        // 3) A finished download of the same name and size — the file is actually on disk already.
        if let size = candidate.totalBytes, size > 0 {
            if let existing = downloads.first(where: {
                $0.status == .completed && $0.totalBytes == size && $0.fileName == candidate.fileName
            }) {
                return DuplicateMatch(existing: existing, reason: .sameContent)
            }
        }

        return nil
    }

    // MARK: - Helpers

    /// Whether a download represents something the user *has or is getting* — the only states for
    /// which "you already have this" is true. A failed or canceled download isn't on disk, so
    /// re-adding its URL should just proceed.
    private static func isPresent(_ download: Download) -> Bool {
        switch download.status {
        case .downloading, .queued, .paused, .scheduled, .completed: return true
        case .failed, .canceled: return false
        }
    }

    private static func normalizedHost(_ url: URL) -> String? {
        url.host()?.lowercased()
    }

    /// Two sizes are "compatible" when they're equal, or at least one is unknown (so an absent size
    /// never blocks an otherwise-strong ETag match).
    private static func sizesCompatible(_ a: Int64?, _ b: Int64?) -> Bool {
        guard let a, let b else { return true }
        return a == b
    }
}
