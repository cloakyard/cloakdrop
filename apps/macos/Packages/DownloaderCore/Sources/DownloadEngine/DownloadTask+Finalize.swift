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

        // Capture the part file's location before any destination remapping.
        let partPath = download.partFilePath

        // Auto-categorization: file the finished download into a per-type subfolder.
        if settings.autoCategorize {
            let categoryDir = (download.destinationDirectoryPath as NSString)
                .appendingPathComponent(download.category.displayName)
            download.destinationDirectoryPath = categoryDir
        }

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

        try SegmentedFileWriter.finalize(partPath: partPath, destinationPath: download.destinationFilePath)

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
}
