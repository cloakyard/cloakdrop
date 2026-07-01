import Foundation
import CryptoKit
import DownloadModels

/// Streams a file through a hash function to verify content integrity.
///
/// Uses swift-crypto's incremental hashers so even multi-gigabyte files are verified with
/// a bounded memory footprint. Runs off the cooperative pool via `Task.detached`-friendly
/// chunked reads that yield between blocks.
public enum ChecksumVerifier {

    /// Compute the lowercased hex digest of `fileURL` using `algorithm`.
    public static func hash(
        fileURL: URL,
        algorithm: ChecksumAlgorithm,
        chunkSize: Int = 1 << 20
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        switch algorithm {
        case .md5:
            var hasher = Insecure.MD5()
            try feed(handle: handle, chunkSize: chunkSize) { hasher.update(data: $0) }
            return hasher.finalize().hexString
        case .sha1:
            var hasher = Insecure.SHA1()
            try feed(handle: handle, chunkSize: chunkSize) { hasher.update(data: $0) }
            return hasher.finalize().hexString
        case .sha256:
            var hasher = SHA256()
            try feed(handle: handle, chunkSize: chunkSize) { hasher.update(data: $0) }
            return hasher.finalize().hexString
        }
    }

    /// Verify `fileURL` against an expectation. Throws `DownloadError.checksumMismatch` on failure.
    public static func verify(fileURL: URL, against expectation: ChecksumExpectation) throws {
        let actual = try hash(fileURL: fileURL, algorithm: expectation.algorithm)
        guard actual == expectation.expectedHex else {
            throw DownloadError.checksumMismatch(
                algorithm: expectation.algorithm,
                expected: expectation.expectedHex,
                actual: actual
            )
        }
    }

    private static func feed(
        handle: FileHandle,
        chunkSize: Int,
        _ update: (Data) -> Void
    ) throws {
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            update(chunk)
        }
    }
}

private extension Sequence where Element == UInt8 {
    /// Lowercased hex representation of a digest.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
