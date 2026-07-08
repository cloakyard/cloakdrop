import Foundation
import Testing
@testable import DownloadModels

@Suite("File-name derivation (the single source of truth)")
struct FileNamingTests {

    @Test("A server-suggested name wins, reduced to its last path component")
    func suggestedNameWins() {
        let url = URL(string: "https://host.example/dl?id=42")!
        #expect(FileNaming.fileName(suggested: "installer.dmg", url: url) == "installer.dmg")
        #expect(FileNaming.fileName(suggested: "/packages/installer.dmg", url: url) == "installer.dmg")
    }

    @Test("With no usable suggestion, the name comes from the URL, then the host, then a fallback")
    func fallsBackFromURLToHost() {
        #expect(FileNaming.fileName(suggested: nil, url: URL(string: "https://host.example/files/app.zip")!) == "app.zip")
        #expect(FileNaming.fileName(suggested: "   ", url: URL(string: "https://host.example/files/app.zip")!) == "app.zip")
        #expect(FileNaming.fileName(suggested: nil, url: URL(string: "https://host.example")!) == "host.example")
        #expect(FileNaming.fileName(suggested: nil, url: URL(string: "https://host.example/")!) == "host.example")
    }

    @Test("Bare URL convenience matches the suggested-nil path")
    func bareURLConvenience() {
        #expect(FileNaming.fileName(url: URL(string: "https://host.example/a/b/file.pkg")!) == "file.pkg")
    }
}
