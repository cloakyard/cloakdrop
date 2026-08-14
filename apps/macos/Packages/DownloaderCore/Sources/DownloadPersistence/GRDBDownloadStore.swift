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
        // v1 — the complete initial schema in a single migration. `ifNotExists` keeps this baseline
        // compatible with development databases that recorded the former split migration names;
        // GRDB applies it to generated indexes too. Once the app ships, evolve the schema by
        // appending new `registerMigration("v2…")` blocks below — never edit this v1 block.
        migrator.registerMigration("v1") { db in
            try db.create(table: "queue", options: .ifNotExists) { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("maxConcurrent", .integer).notNull()
                t.column("orderIndex", .integer).notNull()
                t.column("isDefault", .boolean).notNull()
            }
            try db.create(table: "download", options: .ifNotExists) { t in
                t.primaryKey("id", .text)
                t.column("statusKind", .text).notNull().indexed()
                t.column("queueID", .text).notNull().indexed()
                t.column("category", .text).notNull().indexed()
                t.column("createdAt", .double).notNull()
                t.column("orderIndex", .integer).notNull()
                t.column("payload", .blob).notNull()
            }
            try db.create(table: "settings", options: .ifNotExists) { t in
                t.primaryKey("id", .integer)
                t.column("payload", .blob).notNull()
            }
            try db.create(table: "rule", options: .ifNotExists) { t in
                t.primaryKey("id", .text)
                t.column("orderIndex", .integer).notNull()
                t.column("isEnabled", .boolean).notNull()
                t.column("payload", .blob).notNull()
            }
            // Lifetime download stats: one row per calendar day (key "yyyy-MM-dd", the user's local
            // day), so today / this-month / all-time totals are all derivable by SQL sum. Accumulated
            // once per completed download.
            try db.create(table: "statsDaily", options: .ifNotExists) { t in
                t.primaryKey("day", .text)
                t.column("bytes", .integer).notNull().defaults(to: 0)
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

    // MARK: Smart rules

    public func allRules() async throws -> [SmartRule] {
        try await dbQueue.read { [decoder] db in
            let payloads = try Row
                .fetchAll(db, sql: "SELECT payload FROM rule ORDER BY orderIndex")
                .map { $0["payload"] as Data? }
            return payloads.compactMap { data in
                guard let data else { return nil }
                return try? decoder.decode(SmartRule.self, from: data)
            }
        }
    }

    public func save(_ rule: SmartRule) async throws {
        try await dbQueue.write { [encoder] db in
            let payload = try encoder.encode(rule)
            try db.execute(
                sql: """
                INSERT INTO rule (id, orderIndex, isEnabled, payload)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    orderIndex = excluded.orderIndex,
                    isEnabled = excluded.isEnabled,
                    payload = excluded.payload
                """,
                arguments: [rule.id.uuidString, rule.order, rule.isEnabled, payload]
            )
        }
    }

    public func deleteRule(id: UUID) async throws {
        _ = try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM rule WHERE id = ?", arguments: [id.uuidString])
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

    // MARK: Stats

    public func recordDownloadedBytes(_ bytes: Int64, on date: Date) async throws {
        guard bytes > 0 else { return }
        let day = Self.dayKey(date)
        try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO statsDaily (day, bytes) VALUES (?, ?) ON CONFLICT(day) DO UPDATE SET bytes = bytes + excluded.bytes",
                arguments: [day, bytes]
            )
        }
    }

    public func loadStats(asOf date: Date) async throws -> DownloadStats {
        let day = Self.dayKey(date)
        let monthLike = Self.monthPrefix(date) + "-%"
        return try await dbQueue.read { db in
            let today = try Int64.fetchOne(db, sql: "SELECT bytes FROM statsDaily WHERE day = ?", arguments: [day]) ?? 0
            let month = try Int64.fetchOne(
                db, sql: "SELECT COALESCE(SUM(bytes), 0) FROM statsDaily WHERE day LIKE ?", arguments: [monthLike]
            ) ?? 0
            let all = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(bytes), 0) FROM statsDaily") ?? 0
            return DownloadStats(todayBytes: today, monthBytes: month, allTimeBytes: all)
        }
    }

    public func resetStats() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM statsDaily")
        }
    }

    /// "yyyy-MM-dd" for the day `date` falls in, in the user's local time zone (POSIX locale so the
    /// key is stable regardless of UI language). A fresh formatter per call keeps this thread-safe on
    /// the database queue.
    private static func dayKey(_ date: Date) -> String { formatted(date, "yyyy-MM-dd") }
    private static func monthPrefix(_ date: Date) -> String { formatted(date, "yyyy-MM") }
    private static func formatted(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = format
        return f.string(from: date)
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
