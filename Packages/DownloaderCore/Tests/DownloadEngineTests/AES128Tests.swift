import Foundation
import Testing
@testable import DownloadEngine

@Suite("AES-128-CBC (HLS segment decryption)")
struct AES128Tests {
    // A 16-byte key and IV shared by the OpenSSL-computed vectors below.
    private let key = Data((0...15).map { UInt8($0) })                        // 000102…0f
    private let iv = Data((16...31).map { UInt8($0) })                        // 1011…1f

    private func hex(_ string: String) -> Data {
        var data = Data()
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            data.append(UInt8(string[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    @Test("Decrypts an OpenSSL-produced ciphertext (external interop, block-aligned + padding block)")
    func decryptsExternalVector() throws {
        // `openssl enc -aes-128-cbc` (PKCS#7) of "CloakDrop rocks!" (16 bytes → 32-byte cipher).
        let cipher = hex("6c2beaeae4e7f4f4190eadbe4dd087dabbb94f1859859f4862add6245726087f")
        let plain = try AES128.decryptCBC(cipher, key: key, iv: iv)
        #expect(String(data: plain, encoding: .utf8) == "CloakDrop rocks!")
    }

    @Test("Decrypts a short (sub-block) OpenSSL ciphertext")
    func decryptsShortVector() throws {
        let cipher = hex("c4bf014d2d9173dde76ee06db1df83ce")
        let plain = try AES128.decryptCBC(cipher, key: key, iv: iv)
        #expect(String(data: plain, encoding: .utf8) == "hi")
    }

    @Test("Encrypt→decrypt round-trips at several sizes")
    func roundTrips() throws {
        for size in [0, 1, 15, 16, 17, 1024, 4096 + 7] {
            let plaintext = Data((0..<size).map { UInt8($0 & 0xff) })
            let cipher = try AES128.encryptCBC(plaintext, key: key, iv: iv)
            #expect(try AES128.decryptCBC(cipher, key: key, iv: iv) == plaintext)
        }
    }

    @Test("Rejects a wrong-length key or IV")
    func rejectsBadLengths() {
        #expect(throws: AES128.CryptoError.badKeyLength(8)) {
            _ = try AES128.decryptCBC(Data(count: 16), key: Data(count: 8), iv: iv)
        }
        #expect(throws: AES128.CryptoError.badIVLength(4)) {
            _ = try AES128.decryptCBC(Data(count: 16), key: key, iv: Data(count: 4))
        }
    }

    @Test("An explicit 16-byte IV is used verbatim")
    func usesExplicitIV() {
        let explicit = Data(repeating: 0xAB, count: 16)
        #expect(AES128.iv(explicit: explicit, sequenceNumber: 42) == explicit)
    }

    @Test("A missing IV derives from the sequence number, big-endian in the low 8 bytes")
    func derivesIVFromSequence() {
        let derived = AES128.iv(explicit: nil, sequenceNumber: 1)
        var expected = Data(count: 16)
        expected[15] = 1
        #expect(derived == expected)

        // 0x0102 = 258 → low two bytes 0x01, 0x02 at indices 14, 15.
        let derived258 = AES128.iv(explicit: nil, sequenceNumber: 258)
        #expect(derived258[14] == 0x01)
        #expect(derived258[15] == 0x02)
        #expect(derived258.prefix(14).allSatisfy { $0 == 0 })
    }

    @Test("A malformed (non-16) explicit IV falls back to the derived one")
    func ignoresBadExplicitIV() {
        let derived = AES128.iv(explicit: Data(count: 4), sequenceNumber: 7)
        #expect(derived.count == 16)
        #expect(derived[15] == 7)
    }
}
