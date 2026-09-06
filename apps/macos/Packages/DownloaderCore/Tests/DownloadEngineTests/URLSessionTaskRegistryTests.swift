import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadEngine

@Suite("URLSession task registry")
struct URLSessionTaskRegistryTests {
    @Test("Late completion from a replaced session cannot finish a new session's matching task number")
    func replacementSessionsRemainIndependent() async throws {
        let oldSession = URLSession(configuration: .ephemeral)
        let newSession = URLSession(configuration: .ephemeral)
        defer { oldSession.invalidateAndCancel(); newSession.invalidateAndCancel() }
        let url = URL(string: "https://example.com/unused")!
        let oldTask = oldSession.dataTask(with: url)
        let newTask = newSession.dataTask(with: url)
        #expect(oldTask.taskIdentifier == newTask.taskIdentifier)

        let registry = TaskRegistry()
        let (oldStream, oldContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let (newStream, newContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        registry.register(taskID: ObjectIdentifier(oldTask), handler: TaskHandler(data: oldContinuation))
        registry.register(taskID: ObjectIdentifier(newTask), handler: TaskHandler(data: newContinuation))

        #expect(!registry.yield(taskID: ObjectIdentifier(oldTask), data: Data("old".utf8)))
        registry.finish(taskID: ObjectIdentifier(oldTask), error: DownloadError.networkLost)
        #expect(!registry.yield(taskID: ObjectIdentifier(newTask), data: Data("new".utf8)))
        registry.finish(taskID: ObjectIdentifier(newTask), error: nil)

        var oldBytes = Data()
        do {
            for try await chunk in oldStream { oldBytes.append(chunk) }
            Issue.record("Expected the old session's failure")
        } catch { #expect(error as? DownloadError == .networkLost) }
        #expect(oldBytes == Data("old".utf8))
        var newBytes = Data()
        for try await chunk in newStream { newBytes.append(chunk) }
        #expect(newBytes == Data("new".utf8))
    }
}
