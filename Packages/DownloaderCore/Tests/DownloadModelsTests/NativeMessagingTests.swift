import Foundation
import Testing
@testable import DownloadModels

@Suite("Native messaging (stdio framing)")
struct NativeMessagingTests {

    // MARK: Length header

    @Test("Length header is 4 bytes, little-endian")
    func lengthHeaderIsLittleEndian() {
        #expect(Array(NativeMessaging.lengthHeader(for: 0)) == [0, 0, 0, 0])
        #expect(Array(NativeMessaging.lengthHeader(for: 1)) == [1, 0, 0, 0])
        // 258 = 0x0102 → low byte 0x02, next 0x01.
        #expect(Array(NativeMessaging.lengthHeader(for: 258)) == [0x02, 0x01, 0x00, 0x00])
        // 0x01020304 spread across all four bytes, least-significant first.
        #expect(Array(NativeMessaging.lengthHeader(for: 0x0102_0304)) == [0x04, 0x03, 0x02, 0x01])
    }

    @Test("Header round-trips through messageLength")
    func headerRoundTrips() {
        for count in [0, 1, 255, 256, 65_535, 1_000_000] {
            let header = NativeMessaging.lengthHeader(for: count)
            #expect(NativeMessaging.messageLength(fromHeader: header) == count)
        }
    }

    @Test("messageLength rejects a header that isn't exactly 4 bytes")
    func rejectsMalformedHeader() {
        #expect(NativeMessaging.messageLength(fromHeader: Data([1, 2, 3])) == nil)
        #expect(NativeMessaging.messageLength(fromHeader: Data([1, 2, 3, 4, 5])) == nil)
        #expect(NativeMessaging.messageLength(fromHeader: Data()) == nil)
    }

    // MARK: Framing

    @Test("frame prefixes the payload with its little-endian length")
    func framePrefixesLength() throws {
        let payload = Data("{\"ok\":true}".utf8)
        let framed = try NativeMessaging.frame(payload)
        #expect(framed.count == 4 + payload.count)
        #expect(NativeMessaging.messageLength(fromHeader: framed.prefix(4)) == payload.count)
        #expect(framed.suffix(payload.count) == payload)
    }

    @Test("frame rejects a payload past the ceiling")
    func frameRejectsOversized() {
        let huge = Data(count: NativeMessaging.maxMessageLength + 1)
        #expect(throws: NativeMessaging.FramingError.self) {
            _ = try NativeMessaging.frame(huge)
        }
    }

    // MARK: Reading from a pipe

    /// Feed bytes through a real pipe and read them back — exercises the short-read loop and EOF.
    private func read(_ bytes: Data, closeAfter: Bool = true) throws -> [Data] {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(bytes)
        if closeAfter { try pipe.fileHandleForWriting.close() }
        var messages: [Data] = []
        while let message = try NativeMessaging.readMessage(from: pipe.fileHandleForReading) {
            messages.append(message)
        }
        return messages
    }

    @Test("Reads a single framed message back verbatim")
    func readsSingleMessage() throws {
        let payload = Data("hello native world".utf8)
        let messages = try read(NativeMessaging.frame(payload))
        #expect(messages == [payload])
    }

    @Test("Reads several back-to-back messages in order")
    func readsMultipleMessages() throws {
        let a = Data("first".utf8), b = Data("second".utf8), c = Data("third".utf8)
        var stream = Data()
        stream.append(try NativeMessaging.frame(a))
        stream.append(try NativeMessaging.frame(b))
        stream.append(try NativeMessaging.frame(c))
        #expect(try read(stream) == [a, b, c])
    }

    @Test("Clean EOF with no data yields no messages")
    func cleanEOFYieldsNothing() throws {
        #expect(try read(Data()) == [])
    }

    @Test("A truncated body stops the stream instead of returning garbage")
    func truncatedBodyStops() throws {
        // Declare 100 bytes but supply only 3, then EOF.
        var stream = NativeMessaging.lengthHeader(for: 100)
        stream.append(Data([1, 2, 3]))
        #expect(try read(stream) == [])
    }

    @Test("A header declaring more than the ceiling throws")
    func oversizedDeclaredLengthThrows() throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(NativeMessaging.lengthHeader(for: NativeMessaging.maxMessageLength + 1))
        try pipe.fileHandleForWriting.close()
        #expect(throws: NativeMessaging.FramingError.self) {
            _ = try NativeMessaging.readMessage(from: pipe.fileHandleForReading)
        }
    }
}
