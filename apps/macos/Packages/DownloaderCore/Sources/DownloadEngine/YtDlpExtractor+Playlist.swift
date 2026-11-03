import Foundation
import DownloadModels

extension YtDlpExtractor {
    public func playlist(pageURL: URL) async throws -> MediaPlaylist {
        guard ["http", "https"].contains(pageURL.scheme?.lowercased() ?? ""), pageURL.host != nil,
              pageURL.user == nil, pageURL.password == nil else { throw MediaExtractionError.invalidOutput }
        try Task.checkCancellation()
        let result = try await run(arguments: [
            "--ignore-config", "--no-plugin-dirs", "--no-cache-dir", "--simulate",
            "--flat-playlist", "--yes-playlist", "--playlist-end", String(MediaPlaylist.itemLimit + 1),
            "-J", "--no-warnings", "--no-progress", "--socket-timeout", "20", "--", pageURL.absoluteString
        ])
        guard result.exitCode == 0 else { throw MediaExtractionError.failed(result.stderrTail) }
        return try MediaPlaylist.parse(json: result.stdout)
    }
}

extension MediaPlaylist {
    static func parse(json: Data) throws -> MediaPlaylist {
        guard json.count <= 8 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let rawEntries = object["entries"] as? [Any], !rawEntries.isEmpty else {
            throw MediaExtractionError.invalidOutput
        }
        var seen = Set<URL>()
        let entries = rawEntries.prefix(itemLimit).enumerated().map { offset, raw -> MediaPlaylistEntry in
            let item = raw as? [String: Any] ?? [:]
            let title = String((item["title"] as? String ?? "").prefix(300))
            // Generic multi-video pages give every entry the containing playlist's webpage_url.
            // Use the individual resource in that case; otherwise retain the stable item page.
            let page = item["webpage_url"] as? String
            let resource = item["url"] as? String
            let parent = object["webpage_url"] as? String ?? object["original_url"] as? String
            let address = (page != nil && page != parent ? page : resource) ?? page ?? ""
            var url = URL(string: address)
            if let candidate = url {
                if !["http", "https"].contains(candidate.scheme?.lowercased() ?? "") || candidate.host == nil
                    || candidate.user != nil || candidate.password != nil || item["_type"] as? String == "playlist"
                    || !seen.insert(candidate).inserted { url = nil }
            }
            return MediaPlaylistEntry(index: offset + 1, title: title, pageURL: url)
        }
        return MediaPlaylist(title: String((object["title"] as? String ?? "Playlist").prefix(200)),
                             entries: entries, hasMore: rawEntries.count > itemLimit)
    }
}
