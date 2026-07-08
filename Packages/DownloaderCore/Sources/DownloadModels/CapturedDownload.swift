import Foundation

/// A download captured from outside the app — a `cloakdrop://` link, a browser extension, the
/// share sheet — before it becomes a `DownloadRequest`. It carries the context a gated file
/// needs (referrer, cookies, user-agent, extra headers) so the transfer reproduces the browser's
/// request.
///
/// This is the single, validated payload every intake path funnels through. It is a pure value
/// type (Foundation only) so it can be parsed and size-checked in one place and unit-tested
/// without any UI or engine. Callers construct it (or `parse` a URL into it) and then map it to a
/// `DownloadRequest` with `toRequest(destinationDirectoryPath:)`.
///
/// `Codable` so it can cross the process boundary between a bundled browser/share extension and
/// the app as JSON in the shared App Group inbox (see `CaptureInbox`).
public struct CapturedDownload: Sendable, Hashable, Codable {
    /// The file to download. Always http/https after validation.
    public var url: URL
    /// For an adaptive source that serves video and audio as *separate* URLs with no manifest (e.g.
    /// YouTube's `adaptiveFormats`), the matching audio-only URL. When present, the app grabs both
    /// `url` (video) and this, and muxes them so the download has sound. Absent for a normal
    /// single-file download. Always http/https after validation. Optional so captures serialized
    /// before this field existed still decode.
    public var audioURL: URL?
    /// When true, `url` is a *page* (a YouTube watch page, a Vimeo page, …) to hand to the media
    /// extractor (yt-dlp), which resolves it into the real video/audio formats — rather than a direct
    /// file to download. Optional so captures serialized before this field existed still decode.
    public var extractFromPage: Bool?
    /// A name suggested by the source; sanitized of path separators, may still be overridden.
    public var suggestedFileName: String?
    /// The page the download was initiated from (sent as `Referer`).
    public var referrer: String?
    /// Cookies for this specific download (sent as `Cookie`).
    public var cookies: String?
    /// The capturing browser's user-agent, so the server sees a consistent client.
    public var userAgent: String?
    /// Any additional request headers the source wants applied.
    public var extraHeaders: [String: String]
    /// Where the capture came from — used only to label the confirmation UI.
    public var source: Source

    /// Which intake path produced this capture.
    public enum Source: String, Sendable, Hashable, Codable {
        case urlScheme
        case safariExtension
        case browserExtension
        case shareExtension
        case services
        /// The in-app browser (sniffed candidate, page extraction, or download takeover).
        case builtInBrowser
    }

    /// Size ceilings applied by `validated()`. Every field is bounded so a hostile or malformed
    /// intake (a giant cookie string, hundreds of headers) can't blow up memory or the request.
    public enum Limits {
        public static let fileName = 255          // typical filesystem component limit
        public static let referrer = 4_096
        public static let cookies = 16_384
        public static let userAgent = 1_024
        public static let headerName = 128
        public static let headerValue = 8_192
        public static let headerCount = 24
    }

    /// Why a capture was rejected. `Equatable` so tests can assert the exact failure.
    public enum CaptureError: Error, Equatable {
        case unsupportedAction(String)
        case missingURL
        case invalidURL
        case insecureScheme(String)
        case fieldTooLong(field: String, max: Int)
        case tooManyHeaders(max: Int)
    }

    public init(
        url: URL,
        audioURL: URL? = nil,
        extractFromPage: Bool? = nil,
        suggestedFileName: String? = nil,
        referrer: String? = nil,
        cookies: String? = nil,
        userAgent: String? = nil,
        extraHeaders: [String: String] = [:],
        source: Source
    ) {
        self.url = url
        self.audioURL = audioURL
        self.extractFromPage = extractFromPage
        self.suggestedFileName = suggestedFileName
        self.referrer = referrer
        self.cookies = cookies
        self.userAgent = userAgent
        self.extraHeaders = extraHeaders
        self.source = source
    }

    // MARK: - Validation

    /// Returns `self` if every field is within bounds and the URL is http/https; otherwise throws.
    /// Every intake path must call this before the capture is trusted.
    public func validated() throws -> CapturedDownload {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw CaptureError.insecureScheme(url.scheme ?? "")
        }
        if let audioURL {
            guard let audioScheme = audioURL.scheme?.lowercased(), audioScheme == "http" || audioScheme == "https" else {
                throw CaptureError.insecureScheme(audioURL.scheme ?? "")
            }
        }
        func check(_ value: String?, _ field: String, _ max: Int) throws {
            if let value, value.count > max { throw CaptureError.fieldTooLong(field: field, max: max) }
        }
        try check(suggestedFileName, "filename", Limits.fileName)
        try check(referrer, "referer", Limits.referrer)
        try check(cookies, "cookie", Limits.cookies)
        try check(userAgent, "useragent", Limits.userAgent)
        guard extraHeaders.count <= Limits.headerCount else { throw CaptureError.tooManyHeaders(max: Limits.headerCount) }
        for (name, value) in extraHeaders {
            try check(name, "header-name", Limits.headerName)
            try check(value, "header-value", Limits.headerValue)
        }
        return self
    }

    // MARK: - URL scheme

    /// Parse a `cloakdrop://add?url=…&audio=…&filename=…&referer=…&cookie=…&ua=…&header=Name:Value`
    /// link into a validated capture. Query values are percent-decoded by `URLComponents`; the target
    /// `url` (and `audio`) param must therefore be percent-encoded by the caller when it contains
    /// `&`/`=`. `audio` is the separate audio-only URL for an adaptive grab (video + audio, muxed).
    public static func parse(cloakdropURL url: URL) throws -> CapturedDownload {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw CaptureError.invalidURL
        }
        let action = comps.host?.lowercased() ?? ""
        guard action == "add" else { throw CaptureError.unsupportedAction(action) }

        let items = comps.queryItems ?? []
        func firstValue(_ names: [String]) -> String? {
            for name in names {
                if let value = items.first(where: { $0.name.lowercased() == name })?.value,
                   !value.isEmpty {
                    return value
                }
            }
            return nil
        }

        guard let rawURL = firstValue(["url"]) else { throw CaptureError.missingURL }
        guard let target = URL(string: rawURL) else { throw CaptureError.invalidURL }

        var extraHeaders: [String: String] = [:]
        for item in items where item.name.lowercased() == "header" {
            guard let raw = item.value, let separator = raw.firstIndex(of: ":") else { continue }
            let name = String(raw[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(raw[raw.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { extraHeaders[name] = value }
        }

        let captured = CapturedDownload(
            url: target,
            // A malformed audio value degrades to a video-only grab rather than failing the capture.
            audioURL: firstValue(["audio", "audiourl"]).flatMap { URL(string: $0) },
            extractFromPage: firstValue(["extract", "page"]).map { $0 == "1" || $0.lowercased() == "true" },
            suggestedFileName: sanitizedFileName(firstValue(["filename", "name"])),
            referrer: firstValue(["referer", "referrer"]),
            cookies: firstValue(["cookie", "cookies"]),
            userAgent: firstValue(["ua", "useragent"]),
            extraHeaders: extraHeaders,
            source: .urlScheme
        )
        return try captured.validated()
    }

    /// Rebuild the `cloakdrop://add?…` deep link this capture represents — the inverse of
    /// `parse(cloakdropURL:)`. Used as a fallback hand-off (e.g. the share extension when the shared
    /// inbox is unavailable): `URLComponents` percent-encodes each value, and the parser decodes it
    /// symmetrically, so the target URL's own query round-trips.
    public func cloakdropURL() -> URL? {
        var comps = URLComponents()
        comps.scheme = "cloakdrop"
        comps.host = "add"
        var items = [URLQueryItem(name: "url", value: url.absoluteString)]
        if let audioURL { items.append(URLQueryItem(name: "audio", value: audioURL.absoluteString)) }
        if extractFromPage == true { items.append(URLQueryItem(name: "extract", value: "1")) }
        if let suggestedFileName { items.append(URLQueryItem(name: "filename", value: suggestedFileName)) }
        if let referrer { items.append(URLQueryItem(name: "referer", value: referrer)) }
        if let cookies { items.append(URLQueryItem(name: "cookie", value: cookies)) }
        if let userAgent { items.append(URLQueryItem(name: "ua", value: userAgent)) }
        for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: "header", value: "\(name):\(value)"))
        }
        comps.queryItems = items
        return comps.url
    }

    // MARK: - Browser extension message

    /// Build a validated capture from a browser extension's native message — the loosely-typed
    /// dictionary `runtime.sendNativeMessage` delivers to the Safari handler (keys: `url`,
    /// `audioURL`, `filename`, `referrer`, `cookies`, `userAgent`, `headers`). Blank strings are
    /// treated as absent so the extension can always send the full key set. Runs the same
    /// bounds/scheme checks as every other intake path.
    public static func parse(extensionMessage message: [String: Any], source: Source = .safariExtension) throws -> CapturedDownload {
        func string(_ key: String) -> String? {
            guard let value = message[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let rawURL = string("url") else { throw CaptureError.missingURL }
        guard let target = URL(string: rawURL) else { throw CaptureError.invalidURL }

        var extraHeaders: [String: String] = [:]
        if let headers = message["headers"] as? [String: String] {
            for (name, value) in headers {
                let key = name.trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { extraHeaders[key] = value }
            }
        }

        let captured = CapturedDownload(
            url: target,
            // A malformed audio value degrades to a video-only grab rather than failing the capture.
            audioURL: (string("audioURL") ?? string("audio")).flatMap { URL(string: $0) },
            extractFromPage: (message["extract"] as? Bool) ?? (message["page"] as? Bool) ?? (string("extract") == "1"),
            suggestedFileName: sanitizedFileName(string("filename")),
            referrer: string("referrer"),
            cookies: string("cookies"),
            userAgent: string("userAgent"),
            extraHeaders: extraHeaders,
            source: source
        )
        return try captured.validated()
    }

    /// Strip path separators and control characters from a source-supplied name so it can't
    /// escape the destination directory or carry hidden control bytes. Returns `nil` if nothing
    /// usable remains.
    public static func sanitizedFileName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(cleaned.prefix(Limits.fileName))
        return bounded.isEmpty ? nil : bounded
    }

    // MARK: - Mapping

    /// Fold the capture into a `DownloadRequest` for a destination directory. The user-agent and
    /// any extra headers become request headers; referrer/cookies ride the request's dedicated
    /// fields (the engine turns them into `Referer`/`Cookie`).
    public func toRequest(
        destinationDirectoryPath: String,
        destinationBookmark: Data? = nil,
        queueID: UUID = DownloadQueue.defaultQueueID
    ) -> DownloadRequest {
        var headers = extraHeaders
        if let userAgent { headers["User-Agent"] = userAgent }
        return DownloadRequest(
            url: url,
            suggestedFileName: suggestedFileName,
            destinationDirectoryPath: destinationDirectoryPath,
            destinationBookmark: destinationBookmark,
            queueID: queueID,
            requestHeaders: headers,
            referrer: referrer,
            cookies: cookies
        )
    }
}
