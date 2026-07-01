import Foundation
import CommonCrypto

/// AES-128-CBC decryption for HLS segments (`EXT-X-KEY:METHOD=AES-128`).
///
/// CryptoKit offers only authenticated modes (AES-GCM), not the CBC mode HLS uses, so we reach for
/// the system CommonCrypto — still a first-party framework, no new dependency (per the project's
/// system-frameworks-first rule). PKCS#7 padding, matching the HLS spec.
enum AES128 {
    enum CryptoError: Error, Equatable {
        case badKeyLength(Int)
        case badIVLength(Int)
        case failed(Int32)
    }

    /// The 16-byte IV a segment decrypts with: the explicit `IV` from the playlist when present,
    /// otherwise — per the HLS spec — the segment's media sequence number as a 128-bit big-endian
    /// value (high bytes zero, the number right-aligned in the low 8 bytes).
    static func iv(explicit: Data?, sequenceNumber: Int) -> Data {
        if let explicit, explicit.count == kCCBlockSizeAES128 { return explicit }
        var iv = Data(count: kCCBlockSizeAES128)
        var bigEndian = UInt64(bitPattern: Int64(sequenceNumber)).bigEndian
        withUnsafeBytes(of: &bigEndian) { raw in
            for offset in 0..<8 { iv[8 + offset] = raw[offset] }
        }
        return iv
    }

    /// Decrypt `ciphertext` (a whole segment) with a 16-byte `key` and 16-byte `iv`.
    static func decryptCBC(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(ciphertext, key: key, iv: iv, operation: CCOperation(kCCDecrypt))
    }

    /// Symmetric counterpart, kept internal so the transfer path and its tests share one code path.
    static func encryptCBC(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(plaintext, key: key, iv: iv, operation: CCOperation(kCCEncrypt))
    }

    private static func crypt(_ input: Data, key: Data, iv: Data, operation: CCOperation) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { throw CryptoError.badKeyLength(key.count) }
        guard iv.count == kCCBlockSizeAES128 else { throw CryptoError.badIVLength(iv.count) }

        var output = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let outputCount = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress, input.count,
                            outputBytes.baseAddress, outputCount,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.failed(status) }
        output.removeSubrange(moved..<output.count)
        return output
    }
}
