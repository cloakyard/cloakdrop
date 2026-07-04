import Foundation
import DownloadModels

/// Checksum verification (and sibling auto-discovery) for a finished download, factored out of
/// `DownloadTask.finalize()` to keep that file focused. Pure orchestration over the injected HTTP
/// client — the actual hashing lives in `ChecksumVerifier`, discovery in `ChecksumResolver`.
enum DownloadChecksum {
    struct Outcome {
        var expectation: ChecksumExpectation?
        var verified: Bool?
        /// The file's SHA-256, when this verify pass happened to compute it (i.e. the checksum was
        /// SHA-256) — so the provenance receipt can reuse it instead of hashing the whole file again.
        var sha256: String?
    }

    /// Resolve (auto-discovering a sibling when the user supplied none) and verify `download`'s
    /// checksum according to `settings`. Returns the expectation to record on the download and the
    /// verification result.
    ///
    /// Throws `DownloadError.checksumMismatch` **only** for a user-supplied checksum: a mismatch on
    /// an *auto-discovered* one is reported as `verified == false` (the sibling is a heuristic, so a
    /// mismatch flags the file rather than failing an otherwise-complete download).
    static func resolveAndVerify(
        for download: Download,
        settings: EngineSettings,
        httpClient: any HTTPClient
    ) async throws -> Outcome {
        guard settings.verifyChecksumsAutomatically else {
            return Outcome(expectation: download.checksum, verified: download.checksumVerified)
        }

        var expectation = download.checksum
        let userProvided = expectation != nil
        // No supplied checksum → look for a sibling file published next to the download.
        if expectation == nil, settings.autoDiscoverChecksums {
            expectation = await ChecksumResolver(httpClient: httpClient).discover(
                sourceURL: download.url,
                fileName: (download.destinationFilePath as NSString).lastPathComponent,
                headers: download.requestHeaders,
                username: download.username,
                password: download.password
            )
        }
        // Nothing to verify, or an unusable (all-zero placeholder / malformed) digest — record it
        // for display but make no pass/fail claim. Keeps a placeholder from reading as a mismatch.
        guard let expectation, expectation.isUsable else {
            return Outcome(expectation: expectation, verified: nil)
        }

        let fileURL = URL(fileURLWithPath: download.destinationFilePath)
        let actual = try ChecksumVerifier.hash(fileURL: fileURL, algorithm: expectation.algorithm)
        let matches = actual == expectation.expectedHex
        if !matches, userProvided {
            throw DownloadError.checksumMismatch(
                algorithm: expectation.algorithm,
                expected: expectation.expectedHex,
                actual: actual
            )
        }
        return Outcome(expectation: expectation, verified: matches,
                       sha256: expectation.algorithm == .sha256 ? actual : nil)
    }
}
