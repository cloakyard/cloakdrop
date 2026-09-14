import Foundation
import Testing
@testable import DownloadModels

@Suite("Capture inbox filesystem safety")
struct CaptureInboxTests {
    @Test("Draining bounds files, preserves non-files, and delivers valid captures oldest first")
    func drainsSafely() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inbox = root.appendingPathComponent("captures")
        try manager.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let first = CapturedDownload(url: URL(string: "https://e.com/first")!, source: .shareExtension)
        let second = CapturedDownload(url: URL(string: "https://e.com/second")!, source: .shareExtension)
        for (index, capture) in [first, second].enumerated() {
            let url = inbox.appendingPathComponent("\(index).json")
            try JSONEncoder().encode(capture).write(to: url)
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: url.path)
        }
        let oversized = inbox.appendingPathComponent("huge.json")
        try Data(repeating: 32, count: CaptureInbox.maximumCaptureBytes + 1).write(to: oversized)
        let malformed = inbox.appendingPathComponent("malformed.json")
        try Data("{ broken".utf8).write(to: malformed)
        let outside = root.appendingPathComponent("outside.json")
        try JSONEncoder().encode(first).write(to: outside)
        let link = inbox.appendingPathComponent("link.json")
        try manager.createSymbolicLink(at: link, withDestinationURL: outside)
        let directory = inbox.appendingPathComponent("directory.json")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("Keep me".utf8).write(to: directory.appendingPathComponent("content"))

        #expect(CaptureInbox.drain(from: inbox) == [first, second])
        #expect(!manager.fileExists(atPath: oversized.path))
        #expect(!manager.fileExists(atPath: malformed.path))
        #expect(manager.fileExists(atPath: outside.path))
        #expect(manager.fileExists(atPath: link.path))
        #expect(manager.fileExists(atPath: directory.appendingPathComponent("content").path))
        #expect(CaptureInbox.drain(from: inbox).isEmpty)
    }
}
