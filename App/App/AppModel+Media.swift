import Foundation
import DownloadModels

/// A resolved manifest plus the request context, awaiting the user's quality pick in the media picker.
struct MediaSelection: Identifiable {
    let id = UUID()
    let stream: MediaStream
    let request: DownloadRequest
}

/// Media (HLS/DASH) intake: recognise a streaming manifest, resolve it, let the user pick a quality,
/// and enqueue the grab through the same `DownloadManager` everything else uses.
extension AppModel {
    /// Whether a URL looks like an adaptive-streaming manifest worth offering to grab as media.
    static func isMediaManifest(_ url: URL) -> Bool {
        ["m3u8", "m3u", "mpd"].contains(url.pathExtension.lowercased())
    }

    /// Add a URL — routing an adaptive-streaming manifest through the media flow (resolve → quality
    /// picker) and everything else through the normal download path. If resolution fails or the
    /// manifest turns out to carry no renditions, it quietly falls back to a normal download. A
    /// `preview` (from the add sheet's pre-flight) is forwarded to `add` for content-addressed
    /// duplicate detection; it's irrelevant to the media path (a manifest URL isn't a plain file).
    func grab(_ request: DownloadRequest, preview: LinkPreview? = nil) {
        guard Self.isMediaManifest(request.url) else {
            add(request, preview: preview)
            return
        }
        isResolvingMedia = true
        Task {
            defer { isResolvingMedia = false }
            let headers = Self.mediaHeaders(for: request)
            guard let stream = try? await manager.resolveMediaStream(url: request.url, headers: headers),
                  !stream.variants.isEmpty else {
                add(request)
                return
            }
            pendingMediaSelection = MediaSelection(stream: stream, request: request)
        }
    }

    /// The user picked a variant in the picker: resolve it to a concrete plan and enqueue the grab.
    func confirmMediaSelection(variantID: String) {
        guard let selection = pendingMediaSelection else { return }
        pendingMediaSelection = nil
        Task {
            let headers = Self.mediaHeaders(for: selection.request)
            guard let plan = try? await manager.resolveMediaPlan(
                from: selection.stream,
                variantID: variantID,
                headers: headers
            ) else { return }

            // The add sheet prefills "Save As" from the URL, which for a manifest is a `.m3u8`/`.mpd`
            // name — wrong for the assembled media file (and it'd misclassify the category). Drop it
            // so the engine derives a proper name + container (see `deriveMediaFileName`).
            var request = selection.request
            if let name = request.suggestedFileName,
               ["m3u8", "m3u", "mpd"].contains((name as NSString).pathExtension.lowercased()) {
                request.suggestedFileName = nil
            }
            await manager.addMedia(request, plan: plan)
        }
    }

    func cancelMediaSelection() {
        pendingMediaSelection = nil
    }

    /// Live "segments finished / total" for a media grab — from the progress stream while running,
    /// falling back to the persisted record. `nil` for a normal file download.
    func liveMediaSegments(_ download: Download) -> (completed: Int, total: Int)? {
        guard let plan = download.mediaPlan else { return nil }
        if let live = progress[download.id], let completed = live.completedSegments, let total = live.totalSegments {
            return (completed, total)
        }
        return (download.mediaCompletedSegments, plan.totalSegments)
    }

    /// Fold a request's referrer/cookies into headers for the manifest fetch (mirrors `add`).
    private static func mediaHeaders(for request: DownloadRequest) -> [String: String] {
        var headers = request.requestHeaders
        if let referrer = request.referrer, !referrer.isEmpty { headers["Referer"] = referrer }
        if let cookies = request.cookies, !cookies.isEmpty { headers["Cookie"] = cookies }
        return headers
    }
}
