import Foundation
import DownloadModels

extension DownloadManager {
    /// Replace an ordinary file's address. Partial bytes require a matching strong validator from
    /// the same origin and compatible range/length evidence. No filename or size-only inference.
    /// An explicit restart clears logical progress only after the replacement was successfully probed.
    public func repairDownload(id: UUID, replacementURL: URL, restart: Bool = false) async throws {
        guard let original = downloads[id], original.status.isResumable, !original.isMedia,
              tasks[id] == nil, editingDownloads.insert(id).inserted else {
            throw DownloadEditError.unavailable
        }
        defer {
            editingDownloads.remove(id)
            scheduleAllQueues()
        }
        guard ["http", "https", "ftp", "ftps"].contains(replacementURL.scheme?.lowercased() ?? ""),
              replacementURL.host != nil, replacementURL.user == nil, replacementURL.password == nil else {
            throw DownloadEditError.invalidURL
        }
        let request = HTTPDownloadRequest(
            url: original.url, headers: original.requestHeaders,
            username: original.username, password: original.password
        ).forSource(replacementURL)
        let head = try await httpClient.probe(request)
        guard head.isSuccess else { throw DownloadError.httpStatus(code: head.statusCode) }
        try Task.checkCancellation()
        if original.downloadedBytes > 0, !restart, !canRepair(original, with: head, url: replacementURL) {
            throw DownloadEditError.restartRequired
        }

        let scope = SecurityScope(bookmark: original.destinationBookmark)
        let access = scope.start()
        defer { scope.stop() }
        guard !scope.hasBookmark || access else { throw DownloadEditError.folderUnavailable }
        var repaired = original
        if scope.hasBookmark {
            guard let path = scope.resolvedPath(for: original.destinationDirectoryPath) else {
                throw DownloadEditError.folderUnavailable
            }
            repaired.destinationDirectoryPath = path
            if let bookmark = try scope.refreshedBookmark() { repaired.destinationBookmark = bookmark }
        }
        if original.downloadedBytes > 0, !restart {
            let attributes = try? FileManager.default.attributesOfItem(atPath: repaired.partFilePath)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            guard attributes?[.type] as? FileAttributeType == .typeRegular,
                  original.segments.allSatisfy({ $0.downloadedBytes == 0 || $0.currentOffset <= size }) else {
                throw DownloadEditError.missingPartialData
            }
        }
        repaired.url = replacementURL
        repaired.requestHeaders = request.headers
        repaired.username = request.username
        repaired.password = request.password
        repaired.mirrors = nil
        repaired.etag = head.etag
        repaired.validatorURL = head.finalURL ?? replacementURL
        repaired.totalBytes = head.totalBytes
        repaired.supportsResume = head.acceptsRanges && (head.totalBytes ?? 0) > 0
        if restart || original.downloadedBytes == 0 {
            repaired.segments = []
            repaired.startedAt = nil
            repaired.activeSeconds = nil
            repaired.peakBytesPerSecond = nil
        }
        repaired.checksumVerified = nil
        repaired.signature = nil
        repaired.provenance = nil
        repaired.status = .queued
        await pendingSaves[id]?.value
        try Task.checkCancellation()
        try await store.save(repaired)
        downloads[id] = repaired
        if restart { SegmentedFileWriter.discardPartFile(partPath: repaired.partFilePath) }
        eventContinuation.yield(.downloadUpdated(repaired))
    }

    private func canRepair(_ download: Download, with head: HTTPResponseHead, url: URL) -> Bool {
        guard download.supportsResume, head.acceptsRanges,
              let size = download.totalBytes, size > 0, head.totalBytes == size,
              let validatorURL = download.validatorURL,
              HTTPDownloadRequest.sameOrigin(validatorURL, head.finalURL ?? url),
              validatorURL.path == (head.finalURL ?? url).path,
              let etag = download.etag, etag.hasPrefix("\""), etag.hasSuffix("\""),
              etag.count > 2, head.etag == etag else { return false }
        return true
    }
}
