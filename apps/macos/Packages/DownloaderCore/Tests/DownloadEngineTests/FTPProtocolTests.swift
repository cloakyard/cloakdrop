import Foundation
import Testing
@testable import DownloadEngine

@Suite("FTP protocol parsing")
struct FTPProtocolTests {
    @Test("Frames a single-line reply and leaves the remainder")
    func singleLineReply() {
        let buffer = "220 Welcome\r\n331 Need password\r\n"
        let framed = FTPProtocol.parseReply(from: buffer)
        #expect(framed?.reply.code == 220)
        #expect(framed?.reply.text == "220 Welcome")
        #expect(framed?.remainder == "331 Need password\r\n")
    }

    @Test("Waits for a complete line before framing")
    func incompleteReply() {
        #expect(FTPProtocol.parseReply(from: "220 Welco") == nil)   // no CRLF yet
    }

    @Test("Frames a multi-line reply up to the terminating code line")
    func multiLineReply() {
        let buffer = "230-Welcome to the server\r\n230-Second line\r\n230 Login successful\r\nnext"
        let framed = FTPProtocol.parseReply(from: buffer)
        #expect(framed?.reply.code == 230)
        #expect(framed?.reply.text.contains("Second line") == true)
        #expect(framed?.remainder == "next")
    }

    @Test("An unterminated multi-line reply is not framed")
    func multiLineIncomplete() {
        // Opens 150- but no closing "150 " line yet.
        #expect(FTPProtocol.parseReply(from: "150-Opening data connection\r\n") == nil)
    }

    @Test("Reply classes are categorized per RFC 959")
    func replyClasses() {
        let (r150, _) = FTPProtocol.parseReply(from: "150 Opening\r\n")!
        let (r226, _) = FTPProtocol.parseReply(from: "226 Complete\r\n")!
        let (r331, _) = FTPProtocol.parseReply(from: "331 Password\r\n")!
        let (r550, _) = FTPProtocol.parseReply(from: "550 Not found\r\n")!
        #expect(r150.isPositivePreliminary)
        #expect(r226.isPositiveCompletion)
        #expect(r331.isPositiveIntermediate)
        #expect(r550.isNegative)
    }

    @Test("Parses a PASV host/port tuple")
    func pasv() {
        let addr = FTPProtocol.parsePassiveAddress("227 Entering Passive Mode (192,168,0,10,195,80).")
        #expect(addr?.host == "192.168.0.10")
        #expect(addr?.port == 195 * 256 + 80)
    }

    @Test("Rejects a malformed PASV tuple")
    func pasvMalformed() {
        #expect(FTPProtocol.parsePassiveAddress("227 Entering Passive Mode (192,168,0,10,195)") == nil)
        #expect(FTPProtocol.parsePassiveAddress("227 no parens") == nil)
    }

    @Test("Parses an EPSV port")
    func epsv() {
        #expect(FTPProtocol.parseExtendedPassivePort("229 Entering Extended Passive Mode (|||6446|)") == 6446)
    }

    @Test("Parses a SIZE reply")
    func size() {
        #expect(FTPProtocol.parseSize("213 1048576") == 1_048_576)
        #expect(FTPProtocol.parseSize("213") == nil)
    }

    @Test("Derives the RETR/SIZE path from an FTP URL, defaulting to /")
    func pathFromURL() {
        #expect(FTPProtocol.path(for: URL(string: "ftp://host/dir/file.iso")!) == "/dir/file.iso")
        #expect(FTPProtocol.path(for: URL(string: "ftp://host")!) == "/")
    }
}
