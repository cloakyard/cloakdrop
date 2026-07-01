import Foundation

/// The stdio wire format Chrome, Edge, and Firefox use to talk to a native-messaging host: each
/// message is a 4-byte little-endian length prefix followed by that many bytes of UTF-8 JSON. The
/// host (see the `CloakDropNativeHost` tool) reads capture messages from the extension and replies
/// with a small ack; this type is the pure, unit-tested framing both directions share.
///
/// Foundation-only so it lives in `DownloadModels` alongside `CapturedDownload`/`CaptureInbox` and
/// is exercised by the fast `swift test` loop rather than only through the app project.
public enum NativeMessaging {
    /// Chrome caps a single message from an extension to a host at 1 MiB; we allow more headroom but
    /// still reject anything absurd so a hostile or buggy browser can't make the host allocate
    /// unbounded memory. A real capture — even with a large cookie header — is a few KiB.
    public static let maxMessageLength = 8 * 1024 * 1024

    public enum FramingError: Error, Equatable {
        case messageTooLong(Int)
    }

    /// The 4-byte little-endian length header for a `count`-byte body. Written explicitly rather
    /// than by reinterpreting memory so it's correct regardless of host endianness.
    public static func lengthHeader(for count: Int) -> Data {
        let n = UInt32(truncatingIfNeeded: count)
        return Data([
            UInt8(n & 0xff),
            UInt8((n >> 8) & 0xff),
            UInt8((n >> 16) & 0xff),
            UInt8((n >> 24) & 0xff)
        ])
    }

    /// Decode a 4-byte little-endian length header. `nil` if the header isn't exactly 4 bytes.
    public static func messageLength(fromHeader header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let bytes = [UInt8](header)
        let value = UInt32(bytes[0])
            | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16
            | UInt32(bytes[3]) << 24
        return Int(value)
    }

    /// Prefix `payload` with its little-endian length — the framing for a host→extension reply.
    /// Throws if the payload exceeds `maxMessageLength`.
    public static func frame(_ payload: Data) throws -> Data {
        guard payload.count <= maxMessageLength else { throw FramingError.messageTooLong(payload.count) }
        var framed = lengthHeader(for: payload.count)
        framed.append(payload)
        return framed
    }

    /// Read one length-prefixed message from `handle` (the extension→host direction). Returns `nil`
    /// at clean EOF or a truncated/short read — the host's loop treats that as "the browser closed
    /// the pipe, exit". Throws only when a well-formed header declares a length past the ceiling.
    public static func readMessage(from handle: FileHandle) throws -> Data? {
        try readMessage(fromFileDescriptor: handle.fileDescriptor)
    }

    /// File-descriptor variant used by the host itself (stdin). We read with POSIX `read(2)` rather
    /// than `FileHandle`, whose EOF signalling on a pipe is unreliable across releases — the host's
    /// read loop must see a clean `nil` at EOF or it hangs waiting for a second message.
    public static func readMessage(fromFileDescriptor fd: Int32) throws -> Data? {
        guard let header = readExactly(4, fromFileDescriptor: fd),
              let length = messageLength(fromHeader: header) else { return nil }
        guard length <= maxMessageLength else { throw FramingError.messageTooLong(length) }
        if length == 0 { return Data() }
        return readExactly(length, fromFileDescriptor: fd)
    }

    /// Read exactly `count` bytes with POSIX `read(2)`, looping over the short reads a pipe can
    /// deliver and retrying `EINTR`. Returns `nil` on EOF before `count` bytes (a clean close or a
    /// truncated message) or on a hard read error — unambiguous, unlike `FileHandle`.
    private static func readExactly(_ count: Int, fromFileDescriptor fd: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        var total = 0
        while total < count {
            let n = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress!.advanced(by: total), count - total)
            }
            if n == 0 { return nil }                 // EOF
            if n < 0 {
                if errno == EINTR { continue }        // interrupted — retry
                return nil                            // hard error
            }
            total += n
        }
        return Data(buffer)
    }
}
