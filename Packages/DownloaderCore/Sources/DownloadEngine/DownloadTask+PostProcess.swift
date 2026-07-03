import Foundation
import DownloadModels

/// Post-completion processing that runs at the tail of `finalize`: native archive extraction and the
/// provenance receipt. Split out of `DownloadTask` to keep that file focused on the transfer itself.
extension DownloadTask {
    /// If enabled and the finished file is a `.zip`, extract it natively into a sibling folder named
    /// after the archive. Best-effort and off-actor (extraction is CPU/IO-bound, and a corrupt archive
    /// must never fail an otherwise-complete download).
    func autoExtractIfArchive() async {
        guard settings.autoExtractArchives, ZipArchive.isZip(fileName: download.fileName) else { return }
        let zipPath = download.destinationFilePath
        let folderName = (download.fileName as NSString).deletingPathExtension
        let destination = (download.destinationDirectoryPath as NSString).appendingPathComponent(folderName)
        _ = await Task.detached { try? ZipArchive.extract(zipPath: zipPath, to: destination) }.value
    }

    /// Assemble the verified-download provenance record from the signals gathered during finalize.
    /// The SHA-256 is computed off-actor (it streams the whole file), best-effort — a receipt without
    /// a hash is still useful, and a read failure must not fail a completed download.
    func buildProvenanceReceipt() async -> ProvenanceReceipt {
        let fileURL = URL(fileURLWithPath: download.destinationFilePath)
        let sha256 = await Task.detached { try? ChecksumVerifier.hash(fileURL: fileURL, algorithm: .sha256) }.value
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
