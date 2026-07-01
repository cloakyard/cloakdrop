import Foundation
import GRDB
import DownloadModels

/// SQLite-backed `DownloadStore` using GRDB.
///
/// Design choice: each `Download` is persisted as a JSON payload alongside a handful of
/// indexed scalar columns (status, queue, category, ordering). This keeps the schema
/// stable as the model evolves while preserving the ability to query and sort in SQL —
/// a good fit for a download manager whose record shape grows over time.
public final class GRDBDownloadStore: DownloadStore {
    private let dbQueue: DatabaseQueue
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Open (or create) the database at `url`. Pass an in-memory queue for tests.
    public init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        self.dbQueue = try DatabaseQueue(path: path, configuration: config)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    /// In-memory store for tests.
    public static func inMemory() throws -> GRDBDownloadStore {
        try GRDBDownloadStore(path: ":memory:")
    }

    // MARK: Schema

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1.createTables") { db in
            try db.create(table: "queue") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("maxConcurrent", .integer).notNull()
                t.column("orderIndex", .integer).notNull()
                t.column("isDefault", .boolean).notNull()
            }
            try db.create(table: "download") { t in
                t.primaryKey("id", .text)
                t.column("statusKind", .text).notNull().indexed()
                t.column("queueID", .text).notNull().indexed()
                t.column("category", .text).notNull().indexed()
                t.column("createdAt", .double).notNull()
                t.column("orderIndex", .integer).notNull()
                t.column("payload", .blob).notNull()
            }
            try db.create(table: "settings") { t in
                t.primaryKey("id", .integer)
                t.column("payload", .blob).notNull()
            }
        }
        return migrator
    }

    public func bootstrap() async throws {
        try migrator.migrate(dbQueue)
        try await dbQueue.write { [encoder] db in
            // Seed the default queue exactly once.
            let exists = try Row.fetchOne(
                db,
                sql: "SELECT 1 FROM queue WHERE id = ?",
                arguments: [DownloadQueue.defaultQueueID.uuidString]
            ) != nil
            if !exists {
                let q = DownloadQueue.makeDefault
                try Self.insertQueue(q, into: db)
            }
            // Seed default settings exactly once.
            let hasSettings = try Row.fetchOne(db, sql: "SELECT 1 FROM settings WHERE id = 1") != nil
            if !hasSettings {
                let data = try encoder.encode(EngineSettings.default)
                try db.execute(sql: "INSERT INTO settings (id, payload) VALUES (1, ?)", arguments: [data])
            }
        }
    }

    // MARK: Downloads

    public func allDownloads() async throws -> [Download] {
        try await dbQueue.read { [decoder] db in
            let payloads = try Row
                .fetchAll(db, sql: "SELECT payload FROM download ORDER BY orderIndex, createdAt")
                .map { $0["payload"] as Data? }
            return Self.decodeDownloads(payloads: payloads, decoder: decoder)
        }
    }

    public func download(id: UUID) async throws -> Download? {
        try await dbQueue.read { [decoder] db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT payload FROM download WHERE id = ?",
                arguments: [id.uuidString]
            ), let data = row["payload"] as Data? else { return nil }
            return try decoder.decode(Download.self, from: data)
        }
    }

    public func save(_ download: Download) async throws {
        try await dbQueue.write { [encoder] db in
            try Self.upsertDownload(download, into: db, encoder: encoder)
        }
    }

    public func delete(id: UUID) async throws {
        _ = try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM download WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func deleteCompleted() async throws {
        _ = try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM download WHERE statusKind = 'completed'")
        }
    }

    // MARK: Queues

    public func allQueues() async throws -> [DownloadQueue] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM queue ORDER BY orderIndex").map(Self.decodeQueue)
        }
    }

    public func save(_ queue: DownloadQueue) async throws {
        try await dbQueue.write { db in
            try Self.insertQueue(queue, into: db)
        }
    }

    public func deleteQueue(id: UUID) async throws {
        guard id != DownloadQueue.defaultQueueID else { return } // never delete the default queue
        _ = try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM queue WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: Settings

    public func loadSettings() async throws -> EngineSettings {
        try await dbQueue.read { [decoder] db in
            guard let row = try Row.fetchOne(db, sql: "SELECT payload FROM settings WHERE id = 1"),
                  let data = row["payload"] as Data? else {
                return EngineSettings.default
            }
            // A missing key already falls back to its default via EngineSettings' tolerant
            // decoder; this guards the remaining case of a genuinely corrupt blob.
            return (try? decoder.decode(EngineSettings.self, from: data)) ?? EngineSettings.default
        }
    }

    public func save(settings: EngineSettings) async throws {
        try await dbQueue.write { [encoder] db in
            let data = try encoder.encode(settings)
            try db.execute(
                sql: "INSERT INTO settings (id, payload) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
                arguments: [data]
            )
        }
    }

    // MARK: - Row mapping helpers

    private static func upsertDownload(_ download: Download, into db: Database, encoder: JSONEncoder) throws {
        let payload = try encoder.encode(download)
        try db.execute(
            sql: """
            INSERT INTO download (id, statusKind, queueID, category, createdAt, orderIndex, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                statusKind = excluded.statusKind,
                queueID = excluded.queueID,
                category = excluded.category,
                createdAt = excluded.createdAt,
                orderIndex = excluded.orderIndex,
                payload = excluded.payload
            """,
            arguments: [
                download.id.uuidString,
                download.status.rawKind,
                download.queueID.uuidString,
                download.category.rawValue,
                download.createdAt.timeIntervalSinceReferenceDate,
                download.order,
                payload
            ]
        )
    }

    private static func insertQueue(_ queue: DownloadQueue, into db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO queue (id, name, maxConcurrent, orderIndex, isDefault)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                maxConcurrent = excluded.maxConcurrent,
                orderIndex = excluded.orderIndex,
                isDefault = excluded.isDefault
            """,
            arguments: [
                queue.id.uuidString,
                queue.name,
                queue.maxConcurrentDownloads,
                queue.order,
                queue.isDefault
            ]
        )
    }

    private static func decodeQueue(_ row: Row) -> DownloadQueue {
        DownloadQueue(
            id: UUID(uuidString: row["id"]) ?? UUID(),
            name: row["name"],
            maxConcurrentDownloads: row["maxConcurrent"],
            order: row["orderIndex"],
            isDefault: row["isDefault"]
        )
    }

    /// Decode payloads defensively: a single corrupt or version-incompatible payload is
    /// skipped rather than aborting the whole fetch. The catalog (and the resume invariant
    /// that depends on it) must survive one bad row — losing everything because of one is
    /// worse than losing one. Kept free of GRDB types so it can be unit-tested directly.
    static func decodeDownloads(payloads: [Data?], decoder: JSONDecoder) -> [Download] {
        payloads.compactMap { data in
            guard let data else { return nil }
            return try? decoder.decode(Download.self, from: data)
        }
    }
}
