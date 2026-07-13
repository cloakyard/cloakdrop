import Foundation
import DownloadModels

/// Fetches a sibling checksum file for a finished download and returns the digest to verify against.
///
/// Best-effort by contract: any failure — no sibling exists, a non-2xx response, an oversized or
/// non-text body, a parse miss — yields `nil`, never an error. Auto-discovery must never fail an
/// otherwise-good download. Candidate derivation and parsing live in `ChecksumDiscovery` (pure);
/// this adds only the networking, over the injected `HTTPClient` seam.
public struct ChecksumResolver: Sendable {
    private let httpClient: any HTTPClient
    /// Upper bound on a checksum file's size; anything larger isn't a checksum file and is ignored.
    private let maxBytes: Int

    public init(httpClient: any HTTPClient, maxBytes: Int = 64 * 1024) {
        self.httpClient = httpClient
        self.maxBytes = maxBytes
    }

    /// Try each sibling candidate (strongest algorithm first) and return the first well-formed digest
    /// that matches `fileName`. The download's `headers` and credentials are reused so a checksum
    /// behind the same auth/cookies (it's the same server) is still reachable.
    public func discover(
        sourceURL: URL,
        fileName: String,
        headers: [String: String] = [:],
        username: String? = nil,
        password: String? = nil
    ) async -> ChecksumExpectation? {
        for candidate in ChecksumDiscovery.siblingCandidates(for: sourceURL) {
            let request = HTTPDownloadRequest(url: candidate.url, headers: headers, username: username, password: password)
            guard let text = try? await fetchText(request) else { continue }
            if let expectation = ChecksumDiscovery.parse(text, algorithm: candidate.algorithm, fileName: fileName),
               expectation.isWellFormed {
                return expectation
            }
        }
        return nil
    }

    private func fetchText(_ request: HTTPDownloadRequest) async throws -> String {
        let (head, stream) = try await httpClient.stream(request)
        guard head.isSuccess else { throw ChecksumFetchError.notAChecksumFile } // non-2xx → no sibling
        var data = Data()
        for try await chunk in stream {
            data.append(chunk)
            if data.count > maxBytes { throw ChecksumFetchError.notAChecksumFile } // too big
        }
        guard let text = String(data: data, encoding: .utf8) else { throw ChecksumFetchError.notAChecksumFile }
        return text
    }
}

private enum ChecksumFetchError: Error { case notAChecksumFile }
