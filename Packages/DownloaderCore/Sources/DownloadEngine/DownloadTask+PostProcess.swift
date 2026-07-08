import Foundation
import DownloadModels

/// Post-completion processing that runs at the tail of `finalize`: native archive extraction and the
/// provenance receipt. Split out of `DownloadTask` to keep that file focused on the transfer itself.
extension DownloadTask {
    /// Fetch each requested subtitle, convert it to SubRip, and write a `.srt` sidecar next to the
    /// finished file (`video.en.srt`). Best-effort and never fatal: subtitles are a small text
    /// adornment, so a failed fetch/convert simply writes no file rather than failing a complete video
    /// grab. Fetched here at finalize (not as resumable segments) because they're tiny and the final
    /// destination name — which the sidecar mirrors — isn't known until now.
    func writeSubtitleSidecars(_ subtitles: [MediaSubtitle], headers: [String: String]) async {
        guard !subtitles.isEmpty else { return }
        let base = (download.destinationFilePath as NSString).deletingPathExtension
        var usedPaths = Set<String>()
        for (index, subtitle) in subtitles.enumerated() {
            var texts: [String] = []
            for segment in subtitle.segments {
                let range = segment.byteRange.map { $0.offset...$0.end }
                guard let data = try? await fetchResource(url: segment.url, byteRange: range, headers: headers),
                      let text = String(data: data, encoding: .utf8) else { continue }
                texts.append(text)
            }
            guard !texts.isEmpty else { continue }
            let srt = texts.count > 1 ? SubtitleConverter.segmentsToSRT(texts) : SubtitleConverter.toSRT(texts[0])
            guard let srt, !srt.isEmpty else { continue }

            // `video.en.srt`; fall back to an index when a track has no language/label or would collide.
            let token = subtitle.fileNameToken ?? "\(index + 1)"
            var path = "\(base).\(token).srt"
            if usedPaths.contains(path) { path = "\(base).\(token)-\(index + 1).srt" }
            usedPaths.insert(path)

            guard (try? srt.data(using: .utf8)?.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil else { continue }
            if settings.applyQuarantine { Quarantine.apply(toPath: path, sourceURL: subtitle.segments.first?.url ?? download.url) }
        }
    }

    /// If enabled and the finished file is a `.zip`, extract it natively into a sibling folder named
    /// after the archive. Best-effort and off-actor (extraction is CPU/IO-bound, and a corrupt archive
    /// must never fail an otherwise-complete download). Skipped when checksum verification *failed*, so
    /// a tampered archive is never unpacked. Each extracted file is quarantine-stamped like the archive
    /// itself, so an installer delivered inside a zip still gets vetted by Gatekeeper on first open.
    func autoExtractIfArchive() async {
        guard settings.autoExtractArchives, ZipArchive.isZip(fileName: download.fileName),
              download.checksumVerified != false else { return }
        let zipPath = download.destinationFilePath
        let folderName = (download.fileName as NSString).deletingPathExtension
        let destination = (download.destinationDirectoryPath as NSString).appendingPathComponent(folderName)
        let sourceURL = download.url
        let applyQuarantine = settings.applyQuarantine
        _ = await Task.detached {
            guard let written = try? ZipArchive.extract(zipPath: zipPath, to: destination) else { return }
            if applyQuarantine {
                for path in written { Quarantine.apply(toPath: path, sourceURL: sourceURL) }
            }
        }.value
    }

    /// Assemble the verified-download provenance record from the signals gathered during finalize.
    /// Reuses the SHA-256 from the checksum verify when it computed one; otherwise streams the file once
    /// off-actor (best-effort — a receipt without a hash is still useful, and a read failure must not
    /// fail a completed download). Avoids hashing a multi-GB file twice at completion.
    func buildProvenanceReceipt(precomputedSHA256: String? = nil) async -> ProvenanceReceipt {
        let fileURL = URL(fileURLWithPath: download.destinationFilePath)
        let sha256: String?
        if let precomputedSHA256 {
            sha256 = precomputedSHA256
        } else {
            sha256 = await Task.detached { try? ChecksumVerifier.hash(fileURL: fileURL, algorithm: .sha256) }.value
        }
        let secure = ["https", "ftps"].contains(download.url.scheme?.lowercased() ?? "")
        return ProvenanceReceipt(
            fileName: download.fileName,
            fileSizeBytes: download.totalBytes,
            sourceURL: download.url,
            finalURL: nil,
            mirrors: download.mirrors ?? [],
            transportSecure: secure,
            sha256: sha256,
            expectedChecksum: download.checksum,
            checksumVerified: download.checksumVerified,
            signature: download.signature,
            trustLevel: download.trustLevel,
            generatedAt: Date()
        )
    }
}
