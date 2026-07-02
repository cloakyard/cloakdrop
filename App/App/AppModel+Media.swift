import Foundation
import DownloadModels
import DownloadEngine

/// A resolved media stream plus the request context, awaiting the user's quality pick in the picker.
/// `extracted` is present when the stream came from the *page extractor* (yt-dlp): its variants are
/// already resolved (direct URLs), so confirming builds the plan locally with no further fetch.
struct MediaSelection: Identifiable {
    let id = UUID()
    let stream: MediaStream
    let request: DownloadRequest
    var extracted: ExtractedMedia?
}

/// Media intake: streaming manifests (HLS/DASH) and page URLs (YouTube & 1800+ sites, via yt-dlp)
/// funnel through the same `DownloadManager`. With "Ask me quality" off (the default), the best tier
/// downloads immediately — one click, no picker; with it on, the picker offers every resolution.
extension AppModel {
    /// Whether a URL looks like an adaptive-streaming manifest worth offering to grab as media.
    static func isMediaManifest(_ url: URL) -> Bool {
        ["m3u8", "m3u", "mpd"].contains(url.pathExtension.lowercased())
    }

    /// Add a URL — a streaming manifest routes through the media flow; everything else downloads
    /// normally. If resolution fails or the manifest carries no renditions, it falls back to a normal
    /// download.
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
            routeStream(stream, request: request, extracted: nil)
        }
    }

    /// Grab a *page* URL (a YouTube watch page, etc.): run the media extractor, then auto-download the
    /// best tier with audio — or open the picker when "Ask me quality" is on. On failure, surface an
    /// honest, human message (a protected/SABR stream, a sign-in wall, an unavailable video).
    func grabFromPage(_ capture: CapturedDownload) {
        guard let extractor = mediaExtractor else {
            presentMediaError(String(localized: "Video extraction isn’t available in this build."))
            return
        }
        isResolvingMedia = true
        Task {
            defer { isResolvingMedia = false }
            do {
                let media = try await extractor.extract(
                    pageURL: capture.url, cookies: capture.cookies, userAgent: capture.userAgent
                )
                guard let stream = media.toMediaStream(pageURL: capture.url) else {
                    presentMediaError(Self.friendlyExtractionMessage(.noGrabbableFormats))
                    return
                }
                var request = capture.toRequest(destinationDirectoryPath: AppEnvironment.defaultDownloadsDirectory().path)
                // The extractor's per-format headers (chiefly the exact User-Agent it used) are what
                // actually fetch the deciphered URLs — apply them over the capture's.
                for (name, value) in media.downloadHeaders { request.requestHeaders[name] = value }
                request.suggestedFileName = nil                       // named from the title per tier below
                routeStream(stream, request: request, extracted: media)
            } catch let error as MediaExtractionError {
                presentMediaError(Self.friendlyExtractionMessage(error))
            } catch {
                presentMediaError(String(localized: "Couldn’t read this video."))
            }
        }
    }

    /// Auto-download the best tier, or open the picker when "Ask me quality" is on and there's a real
    /// choice to make.
    private func routeStream(_ stream: MediaStream, request: DownloadRequest, extracted: ExtractedMedia?) {
        if askQualityEnabled, stream.variants.count > 1 {
            pendingMediaSelection = MediaSelection(stream: stream, request: request, extracted: extracted)
            return
        }
        guard let best = stream.bestVariant else { add(request); return }
        Task {
            guard let plan = await buildPlan(from: stream, variantID: best.id, request: request) else {
                // A manifest can still fall back to a plain download; a page URL cannot (it's HTML).
                if extracted == nil { add(request) } else {
                    presentMediaError(String(localized: "Couldn’t prepare this download."))
                }
                return
            }
            await manager.addMedia(named(request, from: extracted, variantID: best.id), plan: plan)
        }
    }

    /// Grab an adaptive source that exposes video and audio as *separate direct URLs* with no manifest:
    /// build a paired plan and enqueue it, downloading both and muxing so the file has sound.
    func grabPairedMedia(_ request: DownloadRequest, audioURL: URL) {
        let plan = MediaPlan.pairedFiles(video: request.url, audio: audioURL)
        Task { await manager.addMedia(request, plan: plan) }
    }

    /// The user picked a variant in the picker: build its plan and enqueue the grab.
    func confirmMediaSelection(variantID: String) {
        guard let selection = pendingMediaSelection else { return }
        pendingMediaSelection = nil
        Task {
            guard let plan = await buildPlan(from: selection.stream, variantID: variantID, request: selection.request) else { return }
            var request = selection.request
            // For a manifest, drop the `.m3u8`/`.mpd` "Save As" name so the engine derives a proper one.
            if selection.extracted == nil, let name = request.suggestedFileName,
               ["m3u8", "m3u", "mpd"].contains((name as NSString).pathExtension.lowercased()) {
                request.suggestedFileName = nil
            }
            await manager.addMedia(named(request, from: selection.extracted, variantID: variantID), plan: plan)
        }
    }

    func cancelMediaSelection() {
        pendingMediaSelection = nil
    }

    /// Build a plan for a chosen variant: pre-resolved extractor streams (their segment is a direct
    /// URL) build locally with no network; an HLS/DASH master variant resolves its media playlist.
    private func buildPlan(from stream: MediaStream, variantID: String, request: DownloadRequest) async -> MediaPlan? {
        guard let variant = stream.variants.first(where: { $0.id == variantID }) else { return nil }
        if variant.segments.isEmpty {
            let headers = Self.mediaHeaders(for: request)
            return try? await manager.resolveMediaPlan(from: stream, variantID: variantID, headers: headers)
        }
        // Pair audio by the group id the mapping set (container-matched), then build locally.
        let audio = stream.audioTracks.first { $0.groupID == variant.audioGroupID } ?? stream.audioTrack(for: variant)
        return stream.plan(for: variant, audio: audio)
    }

    /// Name a page grab from the video title + the chosen format's container; leaves a manifest/plain
    /// request's own name untouched.
    private func named(_ request: DownloadRequest, from extracted: ExtractedMedia?, variantID: String) -> DownloadRequest {
        guard let extracted, request.suggestedFileName == nil else { return request }
        var request = request
        request.suggestedFileName = extracted.downloadName(forFormatID: variantID)
        return request
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

    /// Turn an extraction failure into a short, honest, user-facing line (localized).
    static func friendlyExtractionMessage(_ error: MediaExtractionError) -> String {
        switch error {
        case .noGrabbableFormats:
            return String(localized: "This video is protected — no downloadable stream is available.")
        case .timedOut:
            return String(localized: "Reading the video timed out. Try again.")
        case .toolUnavailable, .invalidOutput:
            return String(localized: "Couldn’t read this video.")
        case .failed(let detail):
            if detail.range(of: "sign in", options: .caseInsensitive) != nil
                || detail.range(of: "bot", options: .caseInsensitive) != nil {
                return String(localized: "This site needs you signed in — open it in your browser, then try again.")
            }
            if detail.range(of: "unavailable", options: .caseInsensitive) != nil {
                return String(localized: "This video is unavailable.")
            }
            return String(localized: "Couldn’t read this video.")
        }
    }
}
