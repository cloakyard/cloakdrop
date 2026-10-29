import Foundation

/// Inspect top-level ISO BMFF boxes without reading media payloads into memory.
enum MP4Container {
    static func isFragmented(at path: String) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        var offset: UInt64 = 0
        while length - offset >= 8 {
            try Task.checkCancellation()
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 8), header.count == 8 else { return false }
            var size = header.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let type = String(bytes: header.suffix(4), encoding: .ascii)
            var headerSize: UInt64 = 8
            if size == 1 {
                guard let extended = try handle.read(upToCount: 8), extended.count == 8 else { return false }
                size = extended.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                headerSize = 16
            } else if size == 0 {
                size = length - offset
            }
            guard size >= headerSize, size <= length - offset else { return false }
            if type == "moof" { return true }
            offset += size
        }
        return false
    }
}
