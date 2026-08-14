import Foundation
import Network
import DownloadModels
import DownloadEngine

enum BoundedHTTPFetchError: Error, Sendable {
    case payloadTooLarge
}

/// Fetches small in-memory resources through the engine's chunked URLSession bridge. The bridge
/// applies backpressure off the main actor; this layer adds a hard aggregate-size ceiling.
enum BoundedHTTPFetcher {
    static func get(
        _ url: URL,
        headers: [String: String] = [:],
        acceptedStatusCodes: Range<Int> = 200..<300,
        maximumBytes: Int,
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        proxies: [Network.ProxyConfiguration]
    ) async throws -> Data {
        let configuration = URLSessionHTTPClient.defaultConfiguration()
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.proxyConfigurations = proxies

        let client = URLSessionHTTPClient(configuration: configuration)
        defer { client.invalidate() }
        let (head, body) = try await client.stream(HTTPDownloadRequest(url: url, headers: headers))
        guard acceptedStatusCodes.contains(head.statusCode) else {
            throw DownloadError.httpStatus(code: head.statusCode)
        }
        guard head.totalBytes.map({ $0 <= maximumBytes }) ?? true else {
            throw BoundedHTTPFetchError.payloadTooLarge
        }

        var data = Data()
        data.reserveCapacity(min(maximumBytes, max(0, Int(clamping: head.totalBytes ?? 0))))
        for try await chunk in body {
            try Task.checkCancellation()
            guard chunk.count <= maximumBytes - data.count else {
                throw BoundedHTTPFetchError.payloadTooLarge
            }
            data.append(chunk)
        }
        try Task.checkCancellation()
        return data
    }
}
