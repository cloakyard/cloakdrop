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
            return String(cString: home)
        }
        return NSHomeDirectory()
    }

    /// Construct a production engine backed by SQLite, real networking, and path monitoring.
    @MainActor
    static func makeManager() throws -> DownloadManager {
        let dbPath = try supportDirectory().appendingPathComponent("cloakdrop.sqlite").path
        let store = try GRDBDownloadStore(path: dbPath)
        return DownloadManager(store: store)
    }
}
