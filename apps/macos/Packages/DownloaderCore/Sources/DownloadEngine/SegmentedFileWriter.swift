import Foundation
import DownloadModels

/// File-system operations for an in-progress download.
///
/// Bytes are written into a single sparse `.cdpart` file. Each segment owns a disjoint,
/// contiguous byte region and writes it through its *own* `SegmentFileHandle`, so parallel
/// segments never contend on a shared handle. When every segment is complete the part file
/// is atomically moved to its final destination.
public enum SegmentedFileWriter {

    /// Ensure the part file exists and (when the size is known) is pre-sized so segments can
    /// seek to their offsets. Safe to call again on resume.
    public static func prepare(partPath: String, totalBytes: Int64?) throws {
        let fm = FileManager.default
        let directory = (partPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: directory) {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: partPath) {
            guard fm.createFile(atPath: partPath, contents: nil) else {
                throw DownloadError.fileSystem(reason: "Could not create \(partPath).")
            }
        }
        if let totalBytes, totalBytes > 0 {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: partPath))
            defer { try? handle.close() }
            let currentSize = (try? handle.seekToEnd()) ?? 0
            if currentSize < UInt64(totalBytes) {
                try handle.truncate(atOffset: UInt64(totalBytes))
            }
        }
    }

    /// Atomically move the finished part file to `destinationPath`, replacing any existing
    /// file there. Creates the destination directory if needed.
    public static func finalize(partPath: String, destinationPath: String) throws {
        let fm = FileManager.default
        let directory = (destinationPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: directory) {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: destinationPath) {
            try fm.removeItem(atPath: destinationPath)
        }
        try fm.moveItem(atPath: partPath, toPath: destinationPath)
    }

    /// Remove the part file (e.g. on cancel with "discard partial data").
    public static func discardPartFile(partPath: String) {
        try? FileManager.default.removeItem(atPath: partPath)
    }

    /// Discard all in-progress data for a download — the `.cdpart` file and, for a media grab,
    /// the `.cdparts` segment directory.
    public static func discardPartData(for download: Download) {
        discardPartFile(partPath: download.partFilePath)
        if download.isMedia {
            try? FileManager.default.removeItem(atPath: download.mediaPartDirectoryPath)
        }
    }
}

/// A write cursor into the part file for a single segment.
///
/// Created and used entirely within one segment's task, so it never crosses a concurrency
/// boundary. Writes advance sequentially from the segment's resume offset.
final class SegmentFileHandle {
    private let handle: FileHandle

    init(partPath: String, startingAtOffset offset: Int64) throws {
        guard let handle = FileHandle(forWritingAtPath: partPath) else {
            throw DownloadError.fileSystem(reason: "Could not open \(partPath) for writing.")
        }
        try handle.seek(toOffset: UInt64(offset))
        self.handle = handle
    }

    func write(_ data: Data) throws {
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw DownloadError.fileSystem(reason: error.localizedDescription)
        }
    }

    /// Flush buffered bytes to disk so progress survives a crash or power loss.
    func synchronize() {
        try? handle.synchronize()
    }

    func close() {
        try? handle.close()
    }
}
