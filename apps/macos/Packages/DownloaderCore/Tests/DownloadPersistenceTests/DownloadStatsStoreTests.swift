import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadPersistence

@Suite("Download stats store")
struct DownloadStatsStoreTests {
    private func freshStore() async throws -> GRDBDownloadStore {
        let store = try GRDBDownloadStore.inMemory()
        try await store.bootstrap()
        return store
    }

    @Test("Buckets by day; today / this-month / all-time sum correctly")
    func accumulatesAndBuckets() async throws {
        let store = try await freshStore()
        let now = Date()
        let lastMonth = now.addingTimeInterval(-60 * 86_400)   // reliably a different calendar month

        try await store.recordDownloadedBytes(100, on: now)
        try await store.recordDownloadedBytes(200, on: now)    // same day → accumulates in one bucket
        try await store.recordDownloadedBytes(50, on: lastMonth)

        let stats = try await store.loadStats(asOf: now)
        #expect(stats.todayBytes == 300)
        #expect(stats.monthBytes == 300)                       // last month's 50 is excluded
        #expect(stats.allTimeBytes == 350)                     // but counts toward all-time
    }

    @Test("Non-positive byte counts are ignored")
    func ignoresNonPositive() async throws {
        let store = try await freshStore()
        let now = Date()
        try await store.recordDownloadedBytes(0, on: now)
        try await store.recordDownloadedBytes(-5, on: now)
        #expect(try await store.loadStats(asOf: now).allTimeBytes == 0)
    }

    @Test("Reset clears every total")
    func resetClears() async throws {
        let store = try await freshStore()
        let now = Date()
        try await store.recordDownloadedBytes(999, on: now)
        try await store.resetStats()
        #expect(try await store.loadStats(asOf: now) == .empty)
    }
}
