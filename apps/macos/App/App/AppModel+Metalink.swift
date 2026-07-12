import Foundation
import AppKit
import UniformTypeIdentifiers
import DownloadModels

/// Metalink intake. A `.metalink`/`.meta4` document describes one file across several mirrors (plus a
/// verifying checksum); we parse it into multi-source `DownloadRequest`s and the engine spreads
/// segments across those mirrors and fails over between them. Reachable by opening/dropping a Metalink
/// file on the app, or via File ▸ Open Metalink…
extension AppModel {
    /// Whether a file URL looks like a Metalink document.
    static func isMetalink(_ url: URL) -> Bool {
        ["metalink", "meta4"].contains(url.pathExtension.lowercased())
    }

    /// Parse a Metalink file and enqueue one multi-source download per file it lists. Surfaces an
    /// honest message if the file can't be read or holds no downloadable source.
    func openMetalink(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            presentMediaError(String(localized: "Couldn’t read that Metalink file."))
            return
        }
        guard let files = try? MetalinkParser.parse(data), !files.isEmpty else {
            presentMediaError(String(localized: "That doesn’t look like a valid Metalink file."))
            return
        }
        let requests = DownloadRequest.requests(
            fromMetalink: files,
            destinationDirectoryPath: AppEnvironment.defaultDownloadsDirectory().path
        )
        guard !requests.isEmpty else {
            presentMediaError(String(localized: "This Metalink lists no downloadable files."))
            return
        }
        for request in requests { add(request) }
    }

    /// Show an open panel for a `.metalink`/`.meta4` file (File ▸ Open Metalink…).
    func importMetalink() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["metalink", "meta4"].compactMap { UTType(filenameExtension: $0) }
        panel.message = String(localized: "Choose a Metalink (.metalink or .meta4) file to download.")
        if panel.runModal() == .OK, let url = panel.url { openMetalink(url) }
    }
}
