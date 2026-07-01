import Foundation

/// The result of an on-device *pre-flight* of a download URL: what the server says about a
/// resource before a single byte of it is committed to disk.
///
/// A pure value type. The engine's `LinkInspector` fills one in from a lightweight probe
/// (resolving redirects, reading `Content-Length` / `Accept-Ranges` / `ETag` / `Content-Type`,
/// and sniffing the file name), so the UI can show the user *what they're about to download* —
/// size, type, whether it resumes, and how many parallel connections it would split into —
/// before they confirm. Privacy-preserving by construction: the only network egress is the
/// same user-entered URL the download itself would hit.
public struct LinkPreview: Sendable, Hashable, Codable {
    /// The URL the user entered / asked to inspect.
    public var requestedURL: URL
    /// Where the request actually landed after following any redirects. Equal to
    /// `requestedURL` when the server didn't redirect.
    public var finalURL: URL
    /// The best file name for the resource — the server's `Content-Disposition` name when it
    /// offers one, otherwise derived from the (redirected) URL.
    public var suggestedFileName: String
    /// Total size in bytes, or `nil` when the server doesn't report a length.
    public var totalBytes: Int64?
    /// Whether the transfer can be resumed & segmented: the server advertised byte-range support
    /// *and* a concrete size. Drives the "Resumable" indicator and the segment estimate.
    public var isResumable: Bool
    /// The resource's MIME type (`Content-Type`, parameters stripped), lowercased, if reported.
    public var mimeType: String?
    /// The resource's `ETag`, if any — a content-derived tag used later to spot duplicates.
    public var etag: String?
    /// How many parallel connections the engine would open for this download under the current
    /// settings. `1` for a non-resumable or small resource; more when it can be segmented.
    public var plannedSegmentCount: Int
    /// The file-type bucket, classified from `suggestedFileName`.
    public var category: FileCategory
    /// The HTTP status of the probe response (usually 200/206).
    public var statusCode: Int

    public init(
        requestedURL: URL,
        finalURL: URL,
        suggestedFileName: String,
        totalBytes: Int64?,
        isResumable: Bool,
        mimeType: String?,
        etag: String?,
        plannedSegmentCount: Int,
        category: FileCategory,
        statusCode: Int
    ) {
        self.requestedURL = requestedURL
        self.finalURL = finalURL
        self.suggestedFileName = suggestedFileName
        self.totalBytes = totalBytes
        self.isResumable = isResumable
        self.mimeType = mimeType
        self.etag = etag
        self.plannedSegmentCount = plannedSegmentCount
        self.category = category
        self.statusCode = statusCode
    }

    /// Whether the server sent the request somewhere other than where it started — worth
    /// surfacing so the user knows the bytes come from a different host/path than they pasted.
    public var wasRedirected: Bool { finalURL != requestedURL }

    /// Whether the resource's size is known (a concrete `Content-Length`/`Content-Range`).
    public var hasKnownSize: Bool { totalBytes != nil }

    /// Whether the engine would open more than one connection — i.e. the download benefits from
    /// multi-segment acceleration.
    public var isMultiSegment: Bool { plannedSegmentCount > 1 }
}
