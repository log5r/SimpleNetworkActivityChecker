import Foundation
import SwiftData
import Testing
@testable import SimpleNetworkActivityChecker

/// `CheckRecord.monitoringPausedAt` を追加する前のモデル（エンティティ名は同じ）。
enum LegacyStoreV1 {
    @Model
    nonisolated final class CheckRecord {
        #Index<CheckRecord>([\.timestamp])

        var timestamp: Date
        var statusRaw: String
        var failedStageRaw: String?
        var triggerRaw: String
        var interfaceName: String?
        var gatewayLatencyMs: Double?
        var internetLatencyMs: Double?
        var dnsLatencyMs: Double?
        var webLatencyMs: Double?

        init(timestamp: Date, statusRaw: String) {
            self.timestamp = timestamp
            self.statusRaw = statusRaw
            triggerRaw = "periodic"
        }
    }

    @Model
    nonisolated final class ErrorLogEntry {
        #Index<ErrorLogEntry>([\.timestamp])

        var timestamp: Date
        var kindRaw: String
        var stageRaw: String?
        var headline: String
        var message: String
        var detail: String
        var interfaceName: String?
        var downtime: Double?
        var reportJSON: Data?

        init(timestamp: Date) {
            self.timestamp = timestamp
            kindRaw = "outage"
            headline = ""
            message = ""
            detail = ""
        }
    }
}

/// 既存のストアが、属性を追加した後のスキーマでもそのまま開けることの確認。
struct StoreMigrationTests {
    @Test func legacyStoreOpensWithMonitoringPausedAt() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "StoreMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "default.store")
        let timestamp = Date(timeIntervalSinceReferenceDate: 800_000_000)

        do {
            let schema = Schema([LegacyStoreV1.CheckRecord.self, LegacyStoreV1.ErrorLogEntry.self])
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            context.insert(LegacyStoreV1.CheckRecord(timestamp: timestamp, statusRaw: "offline"))
            context.insert(LegacyStoreV1.ErrorLogEntry(timestamp: timestamp))
            try context.save()
        }

        let schema = Schema([CheckRecord.self, ErrorLogEntry.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<CheckRecord>())
        #expect(records.count == 1)
        #expect(records.first?.timestamp == timestamp)
        #expect(records.first?.monitoringPausedAt == nil)
        #expect(try context.fetchCount(FetchDescriptor<ErrorLogEntry>()) == 1)

        // 新しい属性も保存できる
        records.first?.monitoringPausedAt = timestamp
        try context.save()
    }
}
