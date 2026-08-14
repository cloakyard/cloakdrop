import Foundation
import GRDB
import Testing
@testable import DownloadModels
@testable import DownloadPersistence

@Suite("GRDB download store")
struct GRDBDownloadStoreTests {
    private func makeStore() async throws -> GRDBDownloadStore {
        let store = try GRDBDownloadStore.inMemory()
        try await store.bootstrap()
        return store
    }

    private func sampleDownload(name: String = "file.zip", status: DownloadStatus = .queued) -> Download {
        var d = Download(
            url: URL(string: "https://example.com/\(name)")!,
            fileName: name,
            destinationDirectoryPath: "/tmp",
            totalBytes: 1000,
            supportsResume: true,
            segments: [DownloadSegment(id: 0, start: 0, end: 999, downloadedBytes: 250)]
        )
        d.status = status
        return d
    }

    @Test("Bootstrap seeds the default queue and settings")
    func bootstrapSeeds() async throws {
        let store = try await makeStore()
        let queues = try await store.allQueues()
        #expect(queues.count == 1)
        #expect(queues.first?.id == DownloadQueue.defaultQueueID)
        #expect(queues.first?.isDefault == true)

        let settings = try await store.loadSettings()
        #expect(settings.defaultSegmentCount == EngineSettings.default.defaultSegmentCount)
    }

    @Test("Bootstrap is idempotent")
    func bootstrapIdempotent() async throws {
        let store = try await makeStore()
        try await store.bootstrap()
        let queues = try await store.allQueues()
        #expect(queues.count == 1)
    }

    @Test(
        "Bootstrap preserves partial and complete pre-consolidation schemas",
        arguments: [false, true]
    )
    func bootstrapMigratesLegacySchema(completeLegacySchema: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GRDBDownloadStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("legacy.sqlite").path

        let legacy = try DatabaseQueue(path: path)
        try await legacy.write { db in
            try db.create(table: "grdb_migrations") { $0.primaryKey("identifier", .text) }
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
            try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('v1.createTables')")
            if completeLegacySchema {
                try db.create(table: "rule") { t in
                    t.primaryKey("id", .text)
                    t.column("orderIndex", .integer).notNull()
                    t.column("isEnabled", .boolean).notNull()
                    t.column("payload", .blob).notNull()
                }
                try db.create(table: "statsDaily") { t in
                    t.primaryKey("day", .text)
                    t.column("bytes", .integer).notNull().defaults(to: 0)
                }
                try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('v2.createRuleTable')")
                try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('v3.createStatsTable')")
            }
            try db.execute(
                sql: "INSERT INTO queue VALUES (?, 'Legacy Queue', 2, 1, 0)",
                arguments: [UUID().uuidString]
            )
        }

        let store = try GRDBDownloadStore(path: path)
        try await store.bootstrap()
        let queues = try await store.allQueues()
        #expect(queues.contains { $0.name == "Legacy Queue" })
        #expect(queues.contains { $0.id == DownloadQueue.defaultQueueID })
        #expect(try await store.allRules().isEmpty)
        #expect(try await store.loadStats(asOf: Date()) == .empty)

        let migrated = try DatabaseQueue(path: path)
        let identifiers = try await migrated.read { db in
            try Set(String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
        }
        #expect(identifiers.contains("v1.createTables"))
        #expect(identifiers.contains("v1"))
    }

    @Test("Save then fetch round-trips a download faithfully")
    func roundTrip() async throws {
        let store = try await makeStore()
        let d = sampleDownload()
        try await store.save(d)

        let fetched = try await store.download(id: d.id)
        #expect(fetched != nil)
        #expect(fetched?.fileName == "file.zip")
        #expect(fetched?.downloadedBytes == 250)
        #expect(fetched?.segments.count == 1)
        #expect(fetched?.supportsResume == true)
    }

    @Test("Upsert updates an existing row rather than duplicating")
    func upsert() async throws {
        let store = try await makeStore()
        var d = sampleDownload()
        try await store.save(d)
        d.status = .completed
        try await store.save(d)

        let all = try await store.allDownloads()
        #expect(all.count == 1)
        #expect(all.first?.status == .completed)
    }

    @Test("A corrupt or version-incompatible payload is skipped, not fatal to the whole load")
    func decodeToleratesBadRows() throws {
        let good = sampleDownload(name: "good.zip")
        let goodData = try JSONEncoder().encode(good)
        let corrupt = Data("{ not valid json".utf8)
        let futureRow = Data(#"{"id":"not-a-uuid","totallyUnknownShape":true}"#.utf8)

        // One good payload sandwiched between two undecodable ones must still come back.
        let decoded = GRDBDownloadStore.decodeDownloads(
            payloads: [corrupt, goodData, nil, futureRow],
            decoder: JSONDecoder()
        )
        #expect(decoded.count == 1)
        #expect(decoded.first?.fileName == "good.zip")
    }

    @Test("Delete removes a single download")
    func delete() async throws {
        let store = try await makeStore()
        let d = sampleDownload()
        try await store.save(d)
        try await store.delete(id: d.id)
        #expect(try await store.download(id: d.id) == nil)
    }

    @Test("deleteCompleted clears only completed rows")
    func deleteCompleted() async throws {
        let store = try await makeStore()
        try await store.save(sampleDownload(name: "a.zip", status: .completed))
        try await store.save(sampleDownload(name: "b.zip", status: .downloading))
        try await store.deleteCompleted()
        let all = try await store.allDownloads()
        #expect(all.count == 1)
        #expect(all.first?.fileName == "b.zip")
    }

    @Test("Custom queues persist; default queue cannot be deleted")
    func queues() async throws {
        let store = try await makeStore()
        let custom = DownloadQueue(name: "Nightly", maxConcurrentDownloads: 2, order: 1)
        try await store.save(custom)
        #expect(try await store.allQueues().count == 2)

        try await store.deleteQueue(id: DownloadQueue.defaultQueueID)
        #expect(try await store.allQueues().contains { $0.id == DownloadQueue.defaultQueueID })

        try await store.deleteQueue(id: custom.id)
        #expect(try await store.allQueues().count == 1)
    }

    @Test("Smart rules persist, upsert, order by priority, and delete")
    func rules() async throws {
        let store = try await makeStore()
        #expect(try await store.allRules().isEmpty)

        var first = SmartRule(name: "videos", order: 1, conditions: [.categoryIs(.video)], actions: [.limitSpeed(bytesPerSecond: 1000)])
        let second = SmartRule(name: "archives", order: 0, conditions: [.fileExtensionIn(["zip"])])
        try await store.save(first)
        try await store.save(second)

        // Returned ordered by `order` (priority), not insertion.
        let all = try await store.allRules()
        #expect(all.map(\.name) == ["archives", "videos"])
        #expect(all.first?.conditions == [.fileExtensionIn(["zip"])])

        // Upsert updates in place rather than duplicating.
        first.isEnabled = false
        try await store.save(first)
        let afterUpsert = try await store.allRules()
        #expect(afterUpsert.count == 2)
        #expect(afterUpsert.first(where: { $0.id == first.id })?.isEnabled == false)

        try await store.deleteRule(id: first.id)
        #expect(try await store.allRules().map(\.name) == ["archives"])
    }

    @Test("Settings persist across save/load")
    func settings() async throws {
        let store = try await makeStore()
        var settings = EngineSettings.default
        settings.defaultSegmentCount = 12
        settings.globalSpeedLimitBytesPerSecond = 5_000_000
        try await store.save(settings: settings)

        let loaded = try await store.loadSettings()
        #expect(loaded.defaultSegmentCount == 12)
        #expect(loaded.globalSpeedLimitBytesPerSecond == 5_000_000)
    }
}
