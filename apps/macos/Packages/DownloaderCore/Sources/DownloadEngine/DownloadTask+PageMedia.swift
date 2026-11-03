import Foundation
import DownloadModels

extension DownloadTask {
    func resolveQueuedMediaPage() async throws {
        guard let selection = download.mediaPageSelection, download.mediaPlan == nil else { return }
        guard let mediaExtractor else { throw DownloadError.underlying(reason: "Video extraction is unavailable in this build.") }
        do {
            let resolved = try await PageMediaResolver(extractor: mediaExtractor, httpClient: httpClient)
                .resolve(url: download.url, selection: selection)
            try Task.checkCancellation()
            download.mediaPlan = resolved.plan
            download.requestHeaders = resolved.headers
            await persist()
            emit(.downloadUpdated(download))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DownloadError.underlying(
                reason: "Could not prepare this playlist item at the selected quality. \(error.localizedDescription)"
            )
        }
    }
}

struct PageMediaResolver {
    let extractor: any MediaExtractor
    let httpClient: any HTTPClient

    func resolve(url: URL, selection: MediaPageSelection) async throws -> (plan: MediaPlan, headers: [String: String]) {
        let media = try await extractor.extract(pageURL: url, cookies: nil, userAgent: nil)
        guard !media.isLive else { throw MediaExtractionError.noGrabbableFormats }
        let resolver = MediaResolver(httpClient: httpClient)
        let audioOnly = selection.quality == .audioOnly
        let format: MediaOutputFormat = audioOnly ? .original : selection.outputFormat
        var stream = media.toMediaStream(pageURL: url, outputFormat: format)
        var headers = media.downloadHeaders
        var fromManifest = false
        if stream == nil, let manifest = media.preferredManifestFormat, let address = manifest.resolvedManifestURL {
            headers = manifest.httpHeaders
            let fetched = try await resolver.fetchManifest(url: address, headers: headers)
            let identified = media.applyingAudioIdentity(to: fetched)
            stream = format == .compatibleMP4 ? identified.compatibleMP4Stream : identified
            fromManifest = true
        }
        guard let stream else { throw MediaExtractionError.noGrabbableFormats }
        if audioOnly, let track = stream.defaultStandaloneAudioTrack {
            if !fromManifest { headers = media.downloadHeaders(forFormatID: track.id) }
            let resolved = try await resolver.resolveAudioTrack(track, headers: headers)
            var plan = stream.audioOnlyPlan(for: resolved)
            plan.outputFormat = .originalAudio
            return (plan, headers)
        }
        let eligible = stream.variants.filter { variant in
            if audioOnly { return variant.isAudioOnly }
            guard variant.hasVideo else { return false }
            guard let cap = selection.quality.maximumHeight else { return true }
            return variant.resolution.map { $0.qualityHeight <= cap } ?? false
        }
        guard let chosen = eligible.sorted(by: MediaVariant.higherQualityFirst).first else {
            throw MediaExtractionError.noGrabbableFormats
        }
        if !fromManifest { headers = media.downloadHeaders(forFormatID: chosen.id) }
        let variant = try await resolver.resolveVariant(chosen, headers: headers)
        var audio = audioOnly ? nil : stream.audioTrack(for: variant)
        if let track = audio { audio = try await resolver.resolveAudioTrack(track, headers: headers) }
        var plan = stream.plan(for: variant, audio: audio)
        plan.outputFormat = audioOnly ? .originalAudio : format
        return (plan, headers)
    }
}
