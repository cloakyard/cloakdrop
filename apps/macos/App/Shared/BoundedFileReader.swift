import Foundation

enum BoundedFileReader {
    enum ReadError: Error, Sendable { case payloadTooLarge }

    static func read(_ file: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0 else { throw ReadError.payloadTooLarge }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumBytes {
            try Task.checkCancellation()
            let remaining = maximumBytes - data.count + 1
            guard let chunk = try handle.read(upToCount: min(64 * 1024, remaining)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else { throw ReadError.payloadTooLarge }
        return data
    }
}
