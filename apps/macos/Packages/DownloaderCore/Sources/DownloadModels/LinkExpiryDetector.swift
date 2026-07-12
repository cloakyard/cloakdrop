import Foundation

/// Reads the expiry deadline out of a pre-signed / tokened download URL by pure inspection of its
/// query string — no network, no allocation of a probe. Covers the encodings the major object stores
/// and CDNs actually ship:
///
/// - **AWS Signature V4** and every S3-compatible store (R2, Spaces, B2, Wasabi, MinIO): `X-Amz-Date`
///   + `X-Amz-Expires` (a start instant plus a lifetime in seconds).
/// - **Google Cloud Storage V4**: `X-Goog-Date` + `X-Goog-Expires`.
/// - **Signature V2 / canned policy** (S3 SigV2, CloudFront canned, GCS V2, Alibaba OSS): an absolute
///   `Expires` epoch next to a signature.
/// - **Azure Blob SAS**: `se` (signed-expiry, ISO-8601) with a `sig`.
/// - **CloudFront custom policy**: a base64 `Policy` carrying `DateLessThan`.
/// - **Edge token auth** (Akamai and kin): `exp=<epoch>` inside `hdnts` / `hdnea` / `__token__`.
/// - **JWT-guarded links**: an `exp` claim inside a JWT query parameter.
/// - A conservative **generic** fallback for plainly-named `expires` / `expiration` parameters.
///
/// When several signals are present the *earliest* wins — that's the instant the link actually dies.
public enum LinkExpiryDetector {

    /// Inspect a URL for an embedded expiry deadline. Returns `nil` when the URL carries none.
    /// Pure and I/O-free — safe to call synchronously as the user types or pastes.
    public static func detect(in url: URL) -> LinkExpiry? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else { return nil }

        // Provider-specific, high-confidence signals first. A URL can carry more than one; the link
        // dies at the earliest deadline, so take the minimum.
        let specific = [
            awsSignedV4(items), googleSignedV4(items), awsSignedV2(items),
            azureSAS(items), cloudFrontPolicy(items), edgeToken(items), jwtExpiry(items)
        ].compactMap { $0 }
        if let earliest = specific.min(by: { $0.expiresAt < $1.expiresAt }) { return earliest }

        // Only when nothing specific matched: a plainly-named `expires=` parameter. Kept last so a
        // stray numeric query value never masquerades as a real, signed deadline.
        return genericExpiry(items)
    }

    // MARK: - Provider strategies

    /// AWS SigV4 (and all S3-compatible stores): `X-Amz-Date` start + `X-Amz-Expires` lifetime.
    private static func awsSignedV4(_ items: [URLQueryItem]) -> LinkExpiry? {
        signedV4(dateParam: "X-Amz-Date", expiresParam: "X-Amz-Expires", source: .awsSignedV4, items)
    }

    /// Google Cloud Storage V4 signed URL — same shape as SigV4 with a `Goog` prefix.
    private static func googleSignedV4(_ items: [URLQueryItem]) -> LinkExpiry? {
        signedV4(dateParam: "X-Goog-Date", expiresParam: "X-Goog-Expires", source: .googleSignedV4, items)
    }

    private static func signedV4(
        dateParam: String, expiresParam: String, source: LinkExpiry.Source, _ items: [URLQueryItem]
    ) -> LinkExpiry? {
        guard let dateString = value(dateParam, in: items),
              let lifetimeString = value(expiresParam, in: items),
              let lifetime = Double(lifetimeString), lifetime > 0, lifetime <= 31_536_000,
              let start = parseBasicISO8601(dateString) else { return nil }
        return bounded(start.addingTimeInterval(lifetime), source)
    }

    /// SigV2 / canned-policy style: an absolute `Expires` epoch, but only when a signing sibling is
    /// present so a plain `?expires=` link isn't misread as a signed one.
    private static func awsSignedV2(_ items: [URLQueryItem]) -> LinkExpiry? {
        let signed = ["Signature", "X-Amz-Signature", "AWSAccessKeyId", "GoogleAccessId",
                      "OSSAccessKeyId", "Key-Pair-Id"].contains { value($0, in: items) != nil }
        guard signed, let raw = value("Expires", in: items), let epoch = Double(raw) else { return nil }
        return bounded(epochDate(epoch), .awsSignedV2)
    }

    /// Azure Blob shared-access signature: `se` (signed expiry, ISO-8601) guarded by a `sig`.
    private static func azureSAS(_ items: [URLQueryItem]) -> LinkExpiry? {
        guard value("sig", in: items) != nil, let expiry = value("se", in: items),
              let date = parseISO8601(expiry) else { return nil }
        return bounded(date, .azureSAS)
    }

    /// CloudFront custom policy: a base64 `Policy` whose JSON carries one or more `DateLessThan`
    /// epoch conditions. The earliest bounds the link.
    private static func cloudFrontPolicy(_ items: [URLQueryItem]) -> LinkExpiry? {
        guard let policy = value("Policy", in: items),
              let data = cloudFrontBase64Decode(policy),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statements = root["Statement"] as? [[String: Any]] else { return nil }
        let epochs: [Double] = statements.compactMap { statement in
            guard let condition = statement["Condition"] as? [String: Any],
                  let dateLessThan = condition["DateLessThan"] as? [String: Any] else { return nil }
            return dateLessThan.values.compactMap(numericValue).min()
        }
        guard let earliest = epochs.min() else { return nil }
        return bounded(epochDate(earliest), .cloudFrontPolicy)
    }

    /// Edge-token auth (Akamai and similar): an `exp=<epoch>` field inside a `~`-delimited token.
    private static func edgeToken(_ items: [URLQueryItem]) -> LinkExpiry? {
        for name in ["hdnts", "hdnea", "__hdnea__", "hdntl", "__token__"] {
            guard let raw = value(name, in: items) else { continue }
            for field in raw.split(whereSeparator: { $0 == "~" || $0 == "&" }) where field.hasPrefix("exp=") {
                if let epoch = Double(field.dropFirst(4)), let expiry = bounded(epochDate(epoch), .edgeToken) {
                    return expiry
                }
            }
        }
        return nil
    }

    /// Any query value that is a JWT with an `exp` claim.
    private static func jwtExpiry(_ items: [URLQueryItem]) -> LinkExpiry? {
        for item in items {
            guard let raw = item.value, let exp = jwtExpiration(raw) else { continue }
            if let expiry = bounded(epochDate(exp), .jwt) { return expiry }
        }
        return nil
    }

    /// Conservative fallback: a plainly-named expiry parameter holding an epoch or ISO-8601 instant,
    /// range-checked so a random numeric param can't fabricate a deadline.
    private static func genericExpiry(_ items: [URLQueryItem]) -> LinkExpiry? {
        let names: Set<String> = ["expires", "expiry", "expire", "expiration", "expires_at",
                                  "valid_until", "validto", "token_expiry", "x-expires", "exp"]
        let dates: [Date] = items.compactMap { item in
            guard names.contains(item.name.lowercased()), let raw = item.value,
                  let date = parseEpochOrISO(raw), plausible(date) else { return nil }
            return date
        }
        guard let earliest = dates.min() else { return nil }
        return LinkExpiry(expiresAt: earliest, source: .generic)
    }

    // MARK: - Parsing helpers

    private static func value(_ name: String, in items: [URLQueryItem]) -> String? {
        items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Decode a JWT's `exp` (RFC 7519 NumericDate — seconds since epoch) without validating its
    /// signature (we only want the deadline, not to trust the token).
    private static func jwtExpiration(_ token: String) -> Double? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].hasPrefix("eyJ"),   // base64url of `{"`
              let payload = base64urlDecode(String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        return object["exp"].flatMap(numericValue)
    }

    /// AWS/GCS basic ISO-8601 (`20260707T120000Z`) — always UTC. Parsed by digit position to sidestep
    /// `DateFormatter` locale pitfalls.
    private static func parseBasicISO8601(_ string: String) -> Date? {
        let digits = Array(string.filter(\.isNumber))
        guard digits.count >= 14, string.uppercased().contains("T") else { return nil }
        func field(_ range: Range<Int>) -> Int? { Int(String(digits[range])) }
        guard let year = field(0..<4), let month = field(4..<6), let day = field(6..<8),
              let hour = field(8..<10), let minute = field(10..<12), let second = field(12..<14) else { return nil }
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)
    }

    /// Full ISO-8601 (Azure `se`, generic ISO params): try internet-date-time, then fractional
    /// seconds, then the shorter Azure-permitted forms.
    private static func parseISO8601(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm'Z'", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = pattern
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    private static func parseEpochOrISO(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber), let value = Double(trimmed) {
            return epochDate(value)
        }
        return parseISO8601(trimmed)
    }

    /// Interpret a Unix timestamp that may be in seconds or milliseconds. A value ≥ 1e12 can only be
    /// milliseconds (1e12 *seconds* is the year 33658), so scale it down.
    private static func epochDate(_ value: Double) -> Date {
        Date(timeIntervalSince1970: value >= 1_000_000_000_000 ? value / 1000 : value)
    }

    private static func numericValue(_ any: Any) -> Double? {
        if let double = any as? Double { return double }
        if let int = any as? Int { return Double(int) }
        if let string = any as? String { return Double(string) }
        return nil
    }

    private static func base64urlDecode(_ string: String) -> Data? {
        var normalized = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while normalized.count % 4 != 0 { normalized.append("=") }
        return Data(base64Encoded: normalized)
    }

    /// CloudFront's URL-safe base64 alphabet swaps `+/=` for `-~_`; reverse that before decoding.
    private static func cloudFrontBase64Decode(_ string: String) -> Data? {
        let normalized = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "=")
            .replacingOccurrences(of: "~", with: "/")
        return Data(base64Encoded: normalized)
    }

    // MARK: - Plausibility

    /// A detected instant is trusted only inside 2000-01-01 … 2100-01-01, so a nonsense numeric param
    /// (or an epoch/millisecond mix-up) can't produce a 1970 or year-9999 "deadline".
    private static let plausibleRange: ClosedRange<TimeInterval> = 946_684_800...4_102_444_800

    private static func plausible(_ date: Date) -> Bool {
        plausibleRange.contains(date.timeIntervalSince1970)
    }

    private static func bounded(_ date: Date, _ source: LinkExpiry.Source) -> LinkExpiry? {
        plausible(date) ? LinkExpiry(expiresAt: date, source: source) : nil
    }
}
