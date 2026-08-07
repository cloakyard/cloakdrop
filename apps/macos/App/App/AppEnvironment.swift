import Foundation
import DownloadEngine
import DownloadPersistence

/// Builds the engine and resolves on-disk locations. The only place that knows where
/// CloakDrop keeps its database and where downloads land by default.
enum AppEnvironment {
    /// The app's private Application Support directory (inside the sandbox container).
    static func supportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let dir = base.appendingPathComponent("CloakDrop", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Default destination for new downloads: the user's **real** `~/Downloads` folder.
    ///
    /// Inside the App Sandbox, `FileManager`'s `.downloadsDirectory` and
    /// `homeDirectoryForCurrentUser` both point into the container, not the real home. The
    /// `com.apple.security.files.downloads.read-write` entitlement, however, grants access to
    /// the actual `~/Downloads`, which we resolve from the real (pre-sandbox) home directory.
    static func defaultDownloadsDirectory() -> URL {
        URL(fileURLWithPath: realHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    /// The user's real home directory (`/Users/<name>`), bypassing the sandbox container.
    private static func realHomeDirectory() -> String {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            let bytes = UnsafeRawBufferPointer(start: home, count: strlen(home))
            return String(bytes: bytes, encoding: .utf8) ?? NSHomeDirectory()
        }
        return NSHomeDirectory()
    }

    /// Construct a production engine backed by SQLite, real networking, and path monitoring.
    @MainActor
    static func makeManager() throws -> DownloadManager {
        let dbPath = try supportDirectory().appendingPathComponent("cloakdrop.sqlite").path
        let store = try GRDBDownloadStore(path: dbPath)
        return DownloadManager(store: store, remuxer: makeRemuxer())
    }

    #if DEBUG
    /// A disposable manager for deterministic marketing captures. Hero fixture mode never starts
    /// this manager, so it performs no network or disk work and cannot touch the user's catalog.
    static func makeHeroFixtureManager() throws -> DownloadManager {
        DownloadManager(store: try GRDBDownloadStore.inMemory())
    }
    #endif

    /// The media remuxer that assembles adaptive grabs into a clean, single file with sound.
    /// AVFoundation runs first (fast, in-process, no bundled dependency — H.264/HEVC + AAC), falling
    /// back to a bundled ffmpeg for the codecs it can't mux (VP9/AV1/Opus). Without a bundled ffmpeg
    /// this is just AVFoundation, and grabs of those exotic codecs ship video-only.
    private static func makeRemuxer() -> any Remuxer {
        var remuxers: [any Remuxer] = [AVFoundationRemuxer()]
        if let ffmpeg = FFmpegMuxer.locate() { remuxers.append(ffmpeg) }
        return remuxers.count == 1 ? remuxers[0] : CompositeRemuxer(remuxers)
    }
}
