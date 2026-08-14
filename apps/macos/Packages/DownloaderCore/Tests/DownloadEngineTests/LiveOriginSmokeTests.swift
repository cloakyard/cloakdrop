import Foundation
import Testing
@testable import DownloadEngine
@testable import DownloadModels
@testable import DownloadPersistence

/// Opt-in end-to-end smoke coverage against caller-selected public origins.
///
/// Normal test runs perform no network I/O. To exercise real origins, provide a comma-separated
/// list, for example:
///
///     CLOAKDROP_LIVE_TEST_URLS='https://origin-one.example/file,https://origin-two.example/file' \
///       swift test --filter LiveOriginSmokeTests
///
/// URLs intentionally live outside the source tree: no third-party service becomes a required or
/// flaky CI dependency, while maintainers can still validate the complete production HTTP path.
@Suite("Live-origin smoke (opt-in)", .serialized)
struct LiveOriginSmokeTests {
    private struct SmokeFailure: Error, CustomStringConvertible {
        let description: String
    }

    @Test("Real URLSession downloads selected origins to complete files")
    func downloadsSelectedOrigins() async throws {
        guard let rawValue = ProcessInfo.processInfo.environment["CLOAKDROP_LIVE_TEST_URLS"],
              !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let entries = rawValue
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !entries.isEmpty else {
            Issue.record("CLOAKDROP_LIVE_TEST_URLS did not contain any URLs")
            return
        }

        for (index, entry) in entries.enumerated() {
            guard let url = URL(string: entry),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil else {
                Issue.record("Invalid HTTP(S) URL in CLOAKDROP_LIVE_TEST_URLS: \(entry)")
                continue
            }

            do {
                try await download(url, index: index)
            } catch {
                Issue.record("Live-origin smoke failed for \(url.absoluteString): \(error)")
            }
        }
    }

    private func download(_ url: URL, index: Int) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloakdrop-live-origin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = URLSessionHTTPClient.defaultConfiguration()
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 4

        let manager = DownloadManager(
            store: try GRDBDownloadStore.inMemory(),
            httpClient: URLSessionHTTPClient(configuration: configuration),
            networkMonitor: AlwaysReachableMonitor()
        )
        try await manager.start()

        // Exercise automatic segment selection (`segmentCount: nil`) without placing aggressive
        // load on public infrastructure. Disable unrelated completion probes and local post-processing.
        var settings = await manager.currentSettings()
        settings.defaultSegmentCount = 4
        settings.maxSegmentCount = 4
        settings.minimumSegmentSizeBytes = 64 * 1024
        settings.maxRetryAttempts = 2
        settings.retryBaseDelaySeconds = 0.25
        settings.retryMaxDelaySeconds = 1
        settings.verifyChecksumsAutomatically = false
        settings.autoDiscoverChecksums = false
        settings.assessSignatures = false
        settings.autoCategorize = false
        settings.applyQuarantine = false
        settings.autoExtractArchives = false
        settings.generateProvenanceReceipts = false
        await manager.updateSettings(settings)

        let added = await manager.add(DownloadRequest(
            url: url,
            suggestedFileName: "live-origin-\(index)-\(UUID().uuidString).bin",
            destinationDirectoryPath: directory.path,
            segmentCount: nil
        ))

        let finished: Download
        do {
            finished = try await waitForSettledDownload(manager, id: added.id, url: url)
        } catch {
            await manager.cancel(id: added.id)
            throw error
        }

        guard finished.status == .completed else {
            if case .failed(let reason) = finished.status {
                throw SmokeFailure(description: "engine reported failure: \(reason)")
            }
            throw SmokeFailure(description: "engine settled as \(finished.status.rawKind), not completed")
        }

        let destination = URL(fileURLWithPath: finished.destinationFilePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw SmokeFailure(description: "completed destination file does not exist")
        }

        let values = try destination.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw SmokeFailure(description: "completed destination is not a regular file")
        }
        let fileSize = Int64(values.fileSize ?? 0)
        guard fileSize > 0 else {
            throw SmokeFailure(description: "completed destination is empty")
        }
        if let expectedSize = finished.totalBytes, fileSize != expectedSize {
            throw SmokeFailure(
                description: "file size \(fileSize) does not match the reported total \(expectedSize)"
            )
        }

        let rangeBehavior = finished.supportsResume ? "honored" : "ignored-or-unavailable"
        let reportedSize = finished.totalBytes.map(String.init) ?? "unknown"
        print(
            "[live-origin] PASS \(url.absoluteString) "
                + "range=\(rangeBehavior) reportedBytes=\(reportedSize) "
                + "fileBytes=\(fileSize) segments=\(finished.segments.count)"
        )
    }

    private func waitForSettledDownload(
        _ manager: DownloadManager,
        id: UUID,
        url: URL,
        timeout: Duration = .seconds(150)
    ) async throws -> Download {
        let deadline = ContinuousClock().now + timeout
        var lastStatus = "missing"

        while ContinuousClock().now < deadline {
            if let download = await manager.snapshot().downloads.first(where: { $0.id == id }) {
                lastStatus = download.status.rawKind
                switch download.status {
                case .completed, .failed, .canceled:
                    return download
                case .queued, .downloading, .paused, .scheduled:
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        throw SmokeFailure(
            description: "timed out after 150 seconds (last status: \(lastStatus)) for \(url.absoluteString)"
        )
    }
}
