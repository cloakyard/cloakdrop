import Foundation
import DownloadModels

/// On-device *pre-flight* of a download URL: one lightweight probe turned into a `LinkPreview`, so
/// the UI can tell the user what they're about to download — final URL after redirects, size, type,
/// resumability, and how many connections it would open — before a byte is committed.
///
/// Pure orchestration over the injected `HTTPClient` seam (so it runs against `MockHTTPClient` in
/// tests). Privacy-preserving: the only egress is the same user-entered URL the download would hit.
public struct LinkInspector: Sendable {
    private let httpClient: any HTTPClient

    public init(httpClient: any HTTPClient) {
        self.httpClient = httpClient
    }

    /// Probe `url` and assemble a `LinkPreview`. Throws whatever the probe throws (unreachable host,
    /// non-success status) so the caller can distinguish "couldn't inspect" from a real result.
    public func inspect(
        url: URL,
        headers: [String: String] = [:],
        username: String? = nil,
        password: String? = nil,
        settings: EngineSettings
    ) async throws -> LinkPreview {
        let head = try await httpClient.probe(
            HTTPDownloadRequest(url: url, headers: headers, username: username, password: password)
        )
        let finalURL = head.finalURL ?? url
        let fileName = Self.fileName(from: head.suggestedFilename, finalURL: finalURL)
        return LinkPreview(
            requestedURL: url,
            finalURL: finalURL,
            suggestedFileName: fileName,
            totalBytes: head.totalBytes,
            isResumable: head.acceptsRanges && head.totalBytes != nil,
            mimeType: head.mimeType,
            etag: head.etag,
            plannedSegmentCount: Self.plannedSegmentCount(
                totalBytes: head.totalBytes,
                acceptsRanges: head.acceptsRanges,
                settings: settings
            ),
            statusCode: head.statusCode
        )
    }

    /// How many parallel connections the engine would open for a resource of this size — mirrors
    /// `DownloadTask.prepareIfNeeded` exactly, so the previewed estimate matches the real transfer.
    /// `1` when the resource is non-resumable or too small to split.
    static func plannedSegmentCount(totalBytes: Int64?, acceptsRanges: Bool, settings: EngineSettings) -> Int {
        guard let total = totalBytes, acceptsRanges, total >= settings.minimumSegmentSizeBytes * 2 else { return 1 }
        let requested = min(settings.maxSegmentCount, max(1, settings.defaultSegmentCount))
        return SegmentPlanner.plan(
            totalBytes: total,
            requestedSegments: requested,
            minimumSegmentSize: settings.minimumSegmentSizeBytes
        ).count
    }

    /// The best name for the resource: the server's `Content-Disposition` name when it offers a
    /// usable one, otherwise the (redirected) URL's last path component, falling back to the host
    /// and finally a generic name. Mirrors `DownloadManager.deriveFileName` for the URL cases.
    static func fileName(from suggested: String?, finalURL: URL) -> String {
        if let suggested {
            let last = (suggested as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !last.isEmpty { return last }
        }
        let last = finalURL.lastPathComponent
        if !last.isEmpty, last != "/" { return last }
        if let host = finalURL.host() { return host }
        return "download"
    }
}
