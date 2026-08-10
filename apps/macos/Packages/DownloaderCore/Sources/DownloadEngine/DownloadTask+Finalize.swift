import Foundation
import DownloadModels

extension DownloadTask {
    func perDownloadLimiters() -> [BandwidthLimiter] {
        var limiters = [globalLimiter]
        if let perDownload = download.speedLimitBytesPerSecond {
            limiters.append(BandwidthLimiter(bytesPerSecond: perDownload))
        }
        return limiters
    }

    func finalize() async throws {
        if download.mediaPlan != nil {
            try await finalizeMedia()
            return
        }
        // For unknown-size single streams, the total is whatever we transferred.
        if download.totalBytes == nil {
            // A server that never advertised a size and then delivered zero bytes (an empty or
            // truncated response that ended without erroring) is not a real download — fail instead
            // of presenting a bogus completed 0-byte file. A genuinely empty resource advertises
            // `Content-Length: 0`, which reaches finalize with a non-nil `totalBytes` and is kept.
            guard download.downloadedBytes > 0 else {
                throw DownloadError.underlying(reason: "The server sent no data for this download.")
            }
            download.totalBytes = download.downloadedBytes
            if !download.segments.isEmpty {
                download.segments[0] = DownloadSegment(
                    id: download.segments[0].id,
                    start: 0,
                    end: max(0, download.downloadedBytes - 1),
                    downloadedBytes: download.downloadedBytes
                )
            }
        }

        // Keep publication metadata local until the move succeeds. If another process creates the
        // destination first, the persisted failed download must still point at its resumable part.
        let partPath = download.partFilePath
        let destinationDirectory = categorizedDirectory(
            download.destinationDirectoryPath, category: download.category
        )
        let destinationPath = (destinationDirectory as NSString)
            .appendingPathComponent(download.fileName)

        // Integrity is established while the file is still private staging data. A user-supplied
        // checksum mismatch must never expose corrupt bytes at the final Finder-visible path.
        let checksum = try await DownloadChecksum.resolveAndVerify(
            for: download,
            settings: settings,
            httpClient: httpClient,
            filePath: partPath
        )
        download.checksum = checksum.expectation
        download.checksumVerified = checksum.verified

        try SegmentedFileWriter.finalize(partPath: partPath, destinationPath: destinationPath)
        download.destinationDirectoryPath = destinationDirectory

        // Stamp it like a browser download so Gatekeeper vets it on first open.
        if settings.applyQuarantine {
            Quarantine.apply(toPath: download.destinationFilePath,
                             sourceURL: download.url,
                             originURL: download.requestHeaders["Referer"].flatMap(URL.init(string:)))
        }

        // Extract only AFTER integrity is established — never unpack an archive whose checksum failed.
        await autoExtractIfArchive()

        // Assess the code signature of installable downloads (.app/.dmg) on-device — reads the
        // signature already in the file; no network, no Gatekeeper round-trip. Best-effort: an
        // unrecognized code object records no signature rather than a misleading "unsigned".
        if settings.assessSignatures, SignatureAssessment.isAssessable(fileName: download.fileName) {
            // Validating a large bundle's seal can take a moment; run it off the actor so this task
            // stays responsive to pause/cancel while the check completes.
            let inspector = signatureInspector
            let fileURL = URL(fileURLWithPath: download.destinationFilePath)
            download.signature = await Task.detached { inspector.assess(fileURL: fileURL) }.value
        }

        if settings.generateProvenanceReceipts {
            download.provenance = await buildProvenanceReceipt(precomputedSHA256: checksum.sha256)
        }
    }

    /// Resolve the final category directory without nesting `Video/Video` when resuming a record
    /// produced by an older build that had already persisted the remapped destination.
    func categorizedDirectory(_ base: String, category: FileCategory) -> String {
        guard settings.autoCategorize,
              (base as NSString).lastPathComponent != category.displayName else { return base }
        return (base as NSString).appendingPathComponent(category.displayName)
    }
}
