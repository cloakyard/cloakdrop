import Foundation

/// The expiry deadline baked into a *pre-signed* or *tokened* download URL, detected by pure
/// inspection of the URL — no network. Many hosts hand out links that stop working at a fixed
/// deadline: AWS S3 and Google Cloud signed URLs, Azure Blob SAS, CloudFront/Akamai edge tokens,
/// and JWT-guarded CDNs all encode "valid until" in the query string. CloakDrop reads that deadline
/// so it can warn *before* a user waits on a link that's already dead, and so a pasted batch can be
/// ordered soonest-to-expire first.
///
/// A pure value type produced by `LinkExpiryDetector`; whether it's *currently* expired is a
/// function of the wall clock, so that lives in `isExpired(asOf:)` rather than being baked in.
public struct LinkExpiry: Sendable, Hashable, Codable {

    /// How the deadline was encoded. A diagnostic that also lets the UI name the source
    /// ("AWS signed URL", "Azure SAS") when it wants to explain *why* a link is time-limited.
    public enum Source: String, Sendable, Codable, CaseIterable {
        /// AWS Signature V4 pre-signed URL: `X-Amz-Date` + `X-Amz-Expires` (S3, Cloudflare R2,
        /// DigitalOcean Spaces, Backblaze B2, Wasabi, MinIO — every S3-compatible store).
        case awsSignedV4
        /// Signature V2 / canned-policy style: an absolute `Expires` epoch alongside a signature
        /// (S3 SigV2, CloudFront canned policy, Google Cloud V2, Alibaba OSS).
        case awsSignedV2
        /// Google Cloud Storage V4 signed URL: `X-Goog-Date` + `X-Goog-Expires`.
        case googleSignedV4
        /// Azure Blob Storage shared-access signature: `se` (signed expiry, ISO-8601) with a `sig`.
        case azureSAS
        /// CloudFront custom policy: a base64 `Policy` whose JSON carries `DateLessThan`.
        case cloudFrontPolicy
        /// Edge-token auth (Akamai and similar): an `exp=<epoch>` field inside `hdnts` / `hdnea` /
        /// `__token__`.
        case edgeToken
        /// A JWT in a query parameter whose payload carries an `exp` claim.
        case jwt
        /// A plainly-named `expires` / `expiry` / `expiration` parameter (epoch or ISO-8601).
        case generic
    }

    /// The absolute instant the link stops working.
    public var expiresAt: Date
    /// The encoding the deadline was read from.
    public var source: Source

    public init(expiresAt: Date, source: Source) {
        self.expiresAt = expiresAt
        self.source = source
    }

    /// Whether the link is already dead as of `now`.
    public func isExpired(asOf now: Date) -> Bool { expiresAt <= now }

    /// Seconds until the deadline as of `now` — negative once it has passed.
    public func timeRemaining(asOf now: Date) -> TimeInterval { expiresAt.timeIntervalSince(now) }
}
