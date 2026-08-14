import Foundation
import Compression
import Darwin

/// A native, dependency-free ZIP extractor built on `Compression.framework` — no bundled `unzip`, no
/// third-party library, fully sandbox-clean. It parses the ZIP central directory and inflates each
/// entry (STORE and DEFLATE, the two methods in virtually every real ZIP), guarding against
/// "Zip Slip" path-escape entries.
///
/// The archive is memory-mapped (`.mappedIfSafe`) rather than read into RAM, so extracting a large
/// download doesn't balloon memory. Output is written entry-by-entry.
enum ZipArchive {
    enum ExtractionError: Error, Equatable {
        case notAZip
        case unsupportedMethod(UInt16)
        case corrupt(String)
        case pathEscape(String)
        case destinationExists(String)
        /// An entry declared an implausible uncompressed size / compression ratio — a likely zip bomb.
        case suspiciousEntry(String)
    }

    /// DEFLATE's theoretical best is ~1032:1; anything far past that is a decompression bomb, not data.
    private static let maxCompressionRatio = 1100.0
    /// Hard ceiling on both a single entry's compressed body and its in-memory decode buffer. Archive
    /// extraction is optional post-processing; keeping one entry below 256 MiB protects the app from
    /// memory pressure while retaining ample headroom for ordinary documents and application bundles.
    static let maximumInMemoryEntryBytes = 256 * 1024 * 1024

    private struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    /// Extract `zipPath` into `destinationDirectory` (created if needed). Returns the list of files
    /// written. Throws on a malformed archive, an unsupported method, or a path-escape attempt.
    @discardableResult
    static func extract(zipPath: String, to destinationDirectory: String) throws -> [String] {
        let data = try Data(contentsOf: URL(fileURLWithPath: zipPath), options: .mappedIfSafe)
        let entries = try readCentralDirectory(data)
        let fm = FileManager.default
        let requestedRoot = URL(fileURLWithPath: destinationDirectory).standardizedFileURL
        try fm.createDirectory(at: requestedRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard Darwin.mkdir(requestedRoot.path, 0o777) == 0 else {
            let code = errno
            if code == EEXIST { throw ExtractionError.destinationExists(requestedRoot.path) }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let destRoot = requestedRoot.resolvingSymlinksInPath()

        var written: [String] = []
        for entry in entries {
            // Skip nameless entries (e.g. an undecodable CP437 name): resolving one yields `destRoot`
            // itself, which would try to write a file over the destination directory and abort the whole
            // extraction. One bad entry must not sink the rest of the archive.
            guard !entry.name.isEmpty else { continue }
            let target = destRoot.appendingPathComponent(entry.name).standardizedFileURL
                .resolvingSymlinksInPath()
            // Zip Slip guard: the resolved path must stay inside the destination root.
            guard target.path == destRoot.path || target.path.hasPrefix(destRoot.path + "/") else {
                throw ExtractionError.pathEscape(entry.name)
            }
            if entry.name.hasSuffix("/") {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = try inflate(entry: entry, from: data)
            // Refuse replacement atomically. Besides preserving user files, this rejects duplicate
            // archive entries that otherwise overwrite an earlier entry with the same path.
            try bytes.write(to: target, options: .withoutOverwriting)
            written.append(target.path)
        }
        return written
    }

    /// Whether a file name looks like a ZIP this extractor should handle.
    static func isZip(fileName: String) -> Bool {
        fileName.lowercased().hasSuffix(".zip")
    }

    // MARK: Central directory

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        guard let eocd = findEOCD(data) else { throw ExtractionError.notAZip }
        let count = Int(readU16(data, eocd + 10))
        var offset = Int(readU32(data, eocd + 16))

        var entries: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= data.count, readU32(data, offset) == 0x0201_4b50 else {
                throw ExtractionError.corrupt("central directory record")
            }
            let method = readU16(data, offset + 10)
            let compressedSize = Int(readU32(data, offset + 20))
            let uncompressedSize = Int(readU32(data, offset + 24))
            let nameLength = Int(readU16(data, offset + 28))
            let extraLength = Int(readU16(data, offset + 30))
            let commentLength = Int(readU16(data, offset + 32))
            let localHeaderOffset = Int(readU32(data, offset + 42))
            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else { throw ExtractionError.corrupt("entry name") }
            let name = String(bytes: data[nameStart..<nameStart + nameLength], encoding: .utf8) ?? ""
            entries.append(Entry(name: name, method: method,
                                 compressedSize: compressedSize, uncompressedSize: uncompressedSize,
                                 localHeaderOffset: localHeaderOffset))
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Scan backward for the End Of Central Directory signature (0x06054b50). It sits within the last
    /// 22 + up-to-65535 comment bytes.
    private static func findEOCD(_ data: Data) -> Int? {
        let minSize = 22
        guard data.count >= minSize else { return nil }
        let searchStart = max(0, data.count - (minSize + 0xFFFF))
        var index = data.count - minSize
        while index >= searchStart {
            if readU32(data, index) == 0x0605_4b50 { return index }
            index -= 1
        }
        return nil
    }

    // MARK: Inflate

    private static func inflate(entry: Entry, from data: Data) throws -> Data {
        let base = entry.localHeaderOffset
        guard base + 30 <= data.count, readU32(data, base) == 0x0403_4b50 else {
            throw ExtractionError.corrupt("local header for \(entry.name)")
        }
        // Local header carries its own name/extra lengths, which may differ from the central copy.
        let nameLength = Int(readU16(data, base + 26))
        let extraLength = Int(readU16(data, base + 28))
        let dataStart = base + 30 + nameLength + extraLength
        guard entry.compressedSize <= Self.maximumInMemoryEntryBytes,
              entry.uncompressedSize <= Self.maximumInMemoryEntryBytes else {
            throw ExtractionError.suspiciousEntry(entry.name)
        }
        guard dataStart + entry.compressedSize <= data.count else {
            throw ExtractionError.corrupt("data range for \(entry.name)")
        }
        // A slice retains the archive's mapped backing instead of copying the compressed body into a
        // second heap buffer. DEFLATE then allocates only the explicitly bounded output buffer.
        let compressed = data[dataStart..<dataStart + entry.compressedSize]

        switch entry.method {
        case 0:   // STORE
            guard entry.compressedSize == entry.uncompressedSize else {
                throw ExtractionError.corrupt("stored size mismatch for \(entry.name)")
            }
            return compressed
        case 8:   // DEFLATE
            // Decompression-bomb guard: reject an absurd ratio (tiny input claiming a huge output) or an
            // entry whose decode buffer would exceed the hard ceiling, before allocating anything.
            let ratio = entry.compressedSize > 0
                ? Double(entry.uncompressedSize) / Double(entry.compressedSize)
                : Double(entry.uncompressedSize)
            guard ratio <= Self.maxCompressionRatio else {
                throw ExtractionError.suspiciousEntry(entry.name)
            }
            return try rawInflate(compressed, expectedSize: entry.uncompressedSize, name: entry.name)
        default:
            throw ExtractionError.unsupportedMethod(entry.method)
        }
    }

    /// Raw-DEFLATE (RFC 1951) decode via Apple's `COMPRESSION_ZLIB`, which — despite the name — decodes
    /// header-less DEFLATE, exactly what ZIP method 8 stores.
    private static func rawInflate(_ input: Data, expectedSize: Int, name: String) throws -> Data {
        if expectedSize == 0 { return Data() }
        var output = Data(count: expectedSize)
        let produced: Int = output.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard produced == expectedSize else { throw ExtractionError.corrupt("inflate size mismatch for \(name)") }
        return output
    }

    // MARK: Little-endian readers

    private static func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16) | (UInt32(data[base + 3]) << 24)
    }
}
