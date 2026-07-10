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
        grabStream(request)
    }

    /// Grab a *known* adaptive stream regardless of its URL's extension — the in-app browser's
    /// sniffer classifies manifests by response MIME type, which the file-extension-based
    /// `isMediaManifest` gate can't see. `forcePicker` opens the quality picker whenever the stream
    /// offers a real choice, even with "Ask me quality" off. Falls back to a plain download.
    func grabStream(_ request: DownloadRequest, forcePicker: Bool = false) {
        beginMediaResolve()
        Task {
            defer { endMediaResolve() }
            let headers = Self.mediaHeaders(for: request)
            guard let stream = try? await manager.resolveMediaStream(url: request.url, headers: headers),
                  !stream.variants.isEmpty else {
                addManifestFallback(request)
                return
            }
            routeStream(stream, request: request, extracted: nil, forcePicker: forcePicker)
        }
    }

    /// Fall back to a plain download of the manifest itself. A browser-supplied title stem — or any
    /// "Save As" name that doesn't name a manifest ("Ep 2.5" would read as extension "5") — only
    /// makes sense for the media output, so drop it and keep the real `.m3u8`/`.mpd` name.
    private func addManifestFallback(_ request: DownloadRequest) {
        var fallback = request
        if let name = fallback.suggestedFileName,
           !["m3u8", "m3u", "mpd"].contains((name as NSString).pathExtension.lowercased()) {
            fallback.suggestedFileName = nil
        }
        add(fallback)
    }

    /// Grab a *page* URL (a YouTube watch page, etc.): run the media extractor, then auto-download the
    /// best tier with audio — or open the picker when "Ask me quality" is on. On failure, surface an
    /// honest, human message (a protected/SABR stream, a sign-in wall, an unavailable video).
    ///
    /// `cookiesFile` (a Netscape jar in a private temp file, deleted here after use) wins over the
    /// capture's flattened cookie header — the in-app browser passes its whole store this way so
    /// multi-domain logins survive extraction. `forcePicker` opens the quality picker whenever
    /// there's a real choice, even with "Ask me quality" off.
    func grabFromPage(
        _ capture: CapturedDownload, cookiesFile: URL? = nil, forcePicker: Bool = false,
        destinationDirectoryPath: String? = nil, destinationBookmark: Data? = nil
    ) {
        guard let extractor = mediaExtractor else {
            if let cookiesFile { try? FileManager.default.removeItem(at: cookiesFile) }
            presentMediaError(String(localized: "Video extraction isn’t available in this build."))
            return
        }
        beginMediaResolve()
        Task {
            defer {
                endMediaResolve()
                if let cookiesFile { try? FileManager.default.removeItem(at: cookiesFile) }
            }
            do {
                let cookies = cookiesFile.map(ExtractionCookies.file) ?? capture.cookies.map(ExtractionCookies.header)
                let media = try await extractor.extract(
                    pageURL: capture.url, cookies: cookies, userAgent: capture.userAgent
                )
                guard let stream = media.toMediaStream(pageURL: capture.url) else {
                    presentMediaError(Self.friendlyExtractionMessage(.noGrabbableFormats))
                    return
                }
                let destination = destinationDirectoryPath ?? AppEnvironment.defaultDownloadsDirectory().path
                var request = capture.toRequest(
                    destinationDirectoryPath: destination, destinationBookmark: destinationBookmark
                )
                // The extractor's per-format headers (chiefly the exact User-Agent it used) are what
                // actually fetch the deciphered URLs — apply them over the capture's.
                for (name, value) in media.downloadHeaders { request.requestHeaders[name] = value }
                request.suggestedFileName = nil                       // named from the title per tier below
                routeStream(stream, request: request, extracted: media, forcePicker: forcePicker)
            } catch let error as MediaExtractionError {
                presentMediaError(Self.friendlyExtractionMessage(error))
            } catch {
                presentMediaError(String(localized: "Couldn’t read this video."))
            }
        }
    }

    /// Grab a *page* URL the user typed into the Add-Download sheet (a YouTube link, etc.): route it
    /// through the page extractor with their chosen destination. Referrer/cookies they entered ride
    /// along for gated pages. The caller only invokes this once `VideoPageDetector` has recognized the
    /// URL and extraction is available.
    ///
    /// It funnels through the same `grabFromPage`/`routeStream` path as a browser grab, so the
    /// Settings ▸ Capture toggles apply here too: "Ask which quality to download" opens the picker
    /// (else the best tier downloads), and "Download subtitles when available" fetches the default
    /// subtitle sidecar on the one-click path.
    func grabPage(
        url: URL, destinationDirectoryPath: String, destinationBookmark: Data?,
        referrer: String?, cookies: String?
    ) {
        let capture = CapturedDownload(
            url: url, extractFromPage: true,
            referrer: referrer, cookies: cookies, source: .manualEntry
        )
        guard let validated = try? capture.validated() else {
            // Shouldn't happen — the sheet only offers this for a normalized http(s) URL — but if the
            // capture is somehow out of bounds, fall back to a plain download rather than silently drop it.
            add(DownloadRequest(url: url, destinationDirectoryPath: destinationDirectoryPath,
                                destinationBookmark: destinationBookmark, referrer: referrer, cookies: cookies))
            return
        }
        grabFromPage(validated, destinationDirectoryPath: destinationDirectoryPath,
                     destinationBookmark: destinationBookmark)
    }

    /// Auto-download the best tier, or open the picker when there's a real choice to make (multiple
    /// qualities, or subtitles to pick) and either "Ask me quality" is on or the caller forces it
    /// (browser grabs always let the user pick the resolution).
    private func routeStream(_ stream: MediaStream, request: DownloadRequest, extracted: ExtractedMedia?, forcePicker: Bool = false) {
        if askQualityEnabled || forcePicker, stream.variants.count > 1 || !stream.subtitleTracks.isEmpty {
            pendingMediaSelection = MediaSelection(stream: stream, request: request, extracted: extracted)
            return
        }
        guard let best = stream.bestVariant else { addManifestFallback(request); return }
        Task {
            let subtitleIDs = defaultSubtitleTrackIDs(for: stream)
            guard let plan = await buildPlan(from: stream, variantID: best.id, subtitleTrackIDs: subtitleIDs,
                                             audioOnly: false, audioTrackID: nil,
                                             isExtracted: extracted != nil, request: request) else {
                // A manifest can still fall back to a plain download; a page URL cannot (it's HTML).
                if extracted == nil { addManifestFallback(request) } else {
                    presentMediaError(String(localized: "Couldn’t prepare this download."))
                }
                return
            }
            await manager.addMedia(named(request, from: extracted, variantID: best.id), plan: plan)
        }
    }

    /// The subtitle track(s) to fetch on the one-click path: the default (else first) track when
    /// "Download subtitles" is on, or none. The picker overrides this per-grab.
    private func defaultSubtitleTrackIDs(for stream: MediaStream) -> [String] {
        guard grabSubtitlesEnabled, !stream.subtitleTracks.isEmpty else { return [] }
        let track = stream.subtitleTracks.first(where: \.isDefault) ?? stream.subtitleTracks.first
        return track.map { [$0.id] } ?? []
    }

    /// Grab an adaptive source that exposes video and audio as *separate direct URLs* with no manifest:
    /// build a paired plan and enqueue it, downloading both and muxing so the file has sound.
    func grabPairedMedia(_ request: DownloadRequest, audioURL: URL) {
        let plan = MediaPlan.pairedFiles(video: request.url, audio: audioURL)
        Task { await manager.addMedia(request, plan: plan) }
    }

    /// The user confirmed the picker: build the plan for the chosen video quality (or audio-only track)
    /// plus any subtitles, and enqueue the grab. In audio-only mode `variantID` names the audio track.
    func confirmMediaSelection(
        variantID: String, subtitleTrackIDs: [String] = [],
        audioOnly: Bool = false, audioTrackID: String? = nil
    ) {
        guard let selection = pendingMediaSelection else { return }
        pendingMediaSelection = nil
        Task {
            guard let plan = await buildPlan(from: selection.stream, variantID: variantID,
                                             subtitleTrackIDs: subtitleTrackIDs, audioOnly: audioOnly,
                                             audioTrackID: audioTrackID,
                                             isExtracted: selection.extracted != nil,
                                             request: selection.request) else {
                // The sheet is already dismissed — a silent no-op would read as a successful grab.
                presentMediaError(String(localized: "Couldn’t prepare this download."))
                return
            }
            await manager.addMedia(named(selection.request, from: selection.extracted, variantID: variantID), plan: plan)
        }
    }

    func cancelMediaSelection() {
        pendingMediaSelection = nil
    }

    /// Build a plan for a chosen variant: pre-resolved extractor streams (their segment is a direct
    /// URL) build locally with no network; an HLS/DASH master variant resolves its media playlist.
    /// `subtitleTrackIDs` names the subtitle tracks to fetch as `.srt` sidecars. When `audioOnly`,
    /// `variantID` instead names the audio track to grab on its own (empty = default track).
    private func buildPlan(
        from stream: MediaStream, variantID: String,
        subtitleTrackIDs: [String], audioOnly: Bool, audioTrackID: String?,
        isExtracted: Bool, request: DownloadRequest
    ) async -> MediaPlan? {
        if audioOnly {
            return await buildAudioOnlyPlan(from: stream, trackID: variantID,
                                            subtitleTrackIDs: subtitleTrackIDs, request: request)
        }
        guard let variant = stream.variants.first(where: { $0.id == variantID }) else { return nil }
        if variant.segments.isEmpty {
            // Manifest master variant — resolve the variant, chosen audio, and subtitles over the network.
            let headers = Self.mediaHeaders(for: request)
            return try? await manager.resolveMediaPlan(
                from: stream, variantID: variantID, audioTrackID: audioTrackID,
                subtitleTrackIDs: subtitleTrackIDs, headers: headers
            )
        }
        // Pre-resolved (extractor / DASH / inline playlist): pair the chosen audio, else the variant's
        // own rendition group, else the stream default. An extractor tier with no audio group is
        // *progressive* — it already carries its sound, so pairing a separate track would download
        // redundant audio and mux a mismatched codec over the tier's own.
        let audio: MediaTrack?
        if let audioTrackID, let chosen = stream.audioTracks.first(where: { $0.id == audioTrackID }) {
            audio = chosen
        } else if let group = variant.audioGroupID {
            let inGroup = stream.audioTracks.filter { $0.groupID == group }
            audio = inGroup.first(where: \.isDefault) ?? inGroup.first ?? stream.audioTrack(for: variant)
        } else if isExtracted {
            audio = nil
        } else {
            audio = stream.audioTrack(for: variant)
        }
        let subtitles = subtitleTrackIDs.compactMap { id in
            stream.subtitleTracks.first { $0.id == id }?.asSubtitle
        }
        return stream.plan(for: variant, audio: audio, subtitles: subtitles)
    }

    /// Build an audio-only plan (the "audio only" verb): grab just the chosen (else default) audio
    /// track, delivered as a clean `.m4a`/native audio file. Pre-resolved tracks build locally; a
    /// manifest audio track resolves its playlist first.
    private func buildAudioOnlyPlan(
        from stream: MediaStream, trackID: String,
        subtitleTrackIDs: [String], request: DownloadRequest
    ) async -> MediaPlan? {
        if let track = stream.audioTracks.first(where: { $0.id == trackID }) ?? stream.defaultAudioTrack {
            if track.segments.isEmpty {
                let headers = Self.mediaHeaders(for: request)
                return try? await manager.resolveAudioOnlyPlan(
                    from: stream, trackID: track.id, subtitleTrackIDs: subtitleTrackIDs, headers: headers
                )
            }
            let subtitles = subtitleTrackIDs.compactMap { id in
                stream.subtitleTracks.first { $0.id == id }?.asSubtitle
            }
            return stream.audioOnlyPlan(for: track, subtitles: subtitles)
        }
        // No separate audio tracks — but `hasGrabbableAudio` (the picker's gate) also admits streams
        // whose only audio is an audio-only *variant* (an HLS master listing the audio rendition as a
        // variant). Grab the best of those as the audio, or the offer would silently do nothing.
        guard let variant = stream.variants.first(where: { $0.id == trackID && $0.isAudioOnly })
                ?? stream.variants.filter(\.isAudioOnly).max(by: { $0.bandwidth < $1.bandwidth }) else {
            return nil
        }
        let subtitles = subtitleTrackIDs.compactMap { id in
            stream.subtitleTracks.first { $0.id == id }?.asSubtitle
        }
        if variant.segments.isEmpty {
            let headers = Self.mediaHeaders(for: request)
            return try? await manager.resolveMediaPlan(
                from: stream, variantID: variant.id, subtitleTrackIDs: subtitleTrackIDs, headers: headers
            )
        }
        return stream.plan(for: variant, audio: nil, subtitles: subtitles)
    }

    /// Name a page grab from the video title + the chosen format's container. For a manifest grab,
    /// a `.m3u8`/`.mpd` "Save As" name would misname the media output — drop it so the engine
    /// derives a proper one; any other supplied name is left untouched.
    private func named(_ request: DownloadRequest, from extracted: ExtractedMedia?, variantID: String) -> DownloadRequest {
        var request = request
        if extracted == nil, let name = request.suggestedFileName,
           ["m3u8", "m3u", "mpd"].contains((name as NSString).pathExtension.lowercased()) {
            request.suggestedFileName = nil
        }
        guard let extracted, request.suggestedFileName == nil else { return request }
        request.suggestedFileName = extracted.downloadName(forFormatID: variantID)
        return request
    }

    /// Live "segments finished / total" for a media grab — from the progress stream while running,
    /// falling back to the persisted record. `nil` for a normal file download.
    func liveMediaSegments(_ download: Download) -> (completed: Int, total: Int)? {
        guard let plan = download.mediaPlan else { return nil }
        if let live = progress[download.id]?.value, let completed = live.completedSegments, let total = live.totalSegments {
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
