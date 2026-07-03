import Foundation
import Compression
import Testing
@testable import DownloadEngine

@Suite("ZIP extraction")
struct ZipArchiveTests {
    // MARK: In-memory ZIP builder (test fixture)

    private struct ZipBuilder {
        struct Item { let name: String; let data: Data; let deflate: Bool }
        private var items: [Item] = []
        mutating func add(_ name: String, _ content: Data, deflate: Bool) {
            items.append(Item(name: name, data: content, deflate: deflate))
        }

        func build() -> Data {
            var out = Data()
            var central = Data()
            var offsets: [Int] = []

            for item in items {
                offsets.append(out.count)
                let stored: Data = item.deflate ? Self.rawDeflate(item.data) : item.data
                let method: UInt16 = item.deflate ? 8 : 0
                let name = Data(item.name.utf8)

                // Local file header.
                out.appendLE(UInt32(0x0403_4b50))
                out.appendLE(UInt16(20)); out.appendLE(UInt16(0)); out.appendLE(method)
                out.appendLE(UInt16(0)); out.appendLE(UInt16(0))     // time/date
                out.appendLE(UInt32(0))                               // crc (extractor ignores)
                out.appendLE(UInt32(stored.count)); out.appendLE(UInt32(item.data.count))
                out.appendLE(UInt16(name.count)); out.appendLE(UInt16(0))
                out.append(name); out.append(stored)
            }

            let centralStart = out.count
            for (index, item) in items.enumerated() {
                let stored: Data = item.deflate ? Self.rawDeflate(item.data) : item.data
                let method: UInt16 = item.deflate ? 8 : 0
                let name = Data(item.name.utf8)
                central.appendLE(UInt32(0x0201_4b50))
                central.appendLE(UInt16(20)); central.appendLE(UInt16(20))
                central.appendLE(UInt16(0)); central.appendLE(method)
                central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
                central.appendLE(UInt32(0))
                central.appendLE(UInt32(stored.count)); central.appendLE(UInt32(item.data.count))
                central.appendLE(UInt16(name.count))
                central.appendLE(UInt16(0)); central.appendLE(UInt16(0))   // extra, comment
                central.appendLE(UInt16(0)); central.appendLE(UInt16(0))   // disk, internal attrs
                central.appendLE(UInt32(0))                                 // external attrs
                central.appendLE(UInt32(offsets[index]))
                central.append(name)
            }
            out.append(central)

            // EOCD.
            out.appendLE(UInt32(0x0605_4b50))
            out.appendLE(UInt16(0)); out.appendLE(UInt16(0))
            out.appendLE(UInt16(items.count)); out.appendLE(UInt16(items.count))
            out.appendLE(UInt32(central.count)); out.appendLE(UInt32(centralStart))
            out.appendLE(UInt16(0))
            return out
        }

        static func rawDeflate(_ data: Data) -> Data {
            let capacity = data.count + 128
            var dst = Data(count: capacity)
            let produced = dst.withUnsafeMutableBytes { d in
                data.withUnsafeBytes { s in
                    compression_encode_buffer(
                        d.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        s.bindMemory(to: UInt8.self).baseAddress!, data.count,
                        nil, COMPRESSION_ZLIB)
                }
            }
            return dst.prefix(produced)
        }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cloakdrop-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Extracts stored and deflated entries, including nested paths")
    func extractsEntries() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bigText = Data(String(repeating: "compress me! ", count: 500).utf8)
        var builder = ZipBuilder()
        builder.add("hello.txt", Data("Hello, World!".utf8), deflate: false)
        builder.add("sub/data.txt", bigText, deflate: true)

        let zipURL = dir.appendingPathComponent("archive.zip")
        try builder.build().write(to: zipURL)

        let out = dir.appendingPathComponent("out")
        let written = try ZipArchive.extract(zipPath: zipURL.path, to: out.path)
        #expect(written.count == 2)

        let hello = try Data(contentsOf: out.appendingPathComponent("hello.txt"))
        #expect(String(decoding: hello, as: UTF8.self) == "Hello, World!")
        let nested = try Data(contentsOf: out.appendingPathComponent("sub/data.txt"))
        #expect(nested == bigText)
    }

    @Test("Rejects a Zip Slip entry that escapes the destination")
    func rejectsZipSlip() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var builder = ZipBuilder()
        builder.add("../escape.txt", Data("pwned".utf8), deflate: false)
        let zipURL = dir.appendingPathComponent("evil.zip")
        try builder.build().write(to: zipURL)

        #expect(throws: ZipArchive.ExtractionError.self) {
            try ZipArchive.extract(zipPath: zipURL.path, to: dir.appendingPathComponent("out").path)
        }
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF)); append(UInt8((value >> 8) & 0xFF))
    }
    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF)); append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF)); append(UInt8((value >> 24) & 0xFF))
    }
}
