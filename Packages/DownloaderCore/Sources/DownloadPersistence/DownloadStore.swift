import Foundation
import DownloadModels

/// Persistence boundary for the engine. Defined as a protocol so the engine can be
/// unit-tested against an in-memory fake with no SQLite involved.
///
/// All methods are `async` and the conformer is `Sendable`, so the store can be shared
/// safely across the engine's actors.
public protocol DownloadStore: Sendable {
    /// Create tables and seed the default queue if needed. Idempotent.
    func bootstrap() async throws

    // MARK: Downloads
    func allDownloads() async throws -> [Download]
    func download(id: UUID) async throws -> Download?
    func save(_ download: Download) async throws
    func delete(id: UUID) async throws
    func deleteCompleted() async throws

    // MARK: Queues
    func allQueues() async throws -> [DownloadQueue]
    func save(_ queue: DownloadQueue) async throws
    func deleteQueue(id: UUID) async throws

    // MARK: Settings
    func loadSettings() async throws -> EngineSettings
    func save(settings: EngineSettings) async throws
}
