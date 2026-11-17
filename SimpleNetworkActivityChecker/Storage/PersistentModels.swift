import Foundation
import SwiftData

/// 1 回の接続チェックの記録（統計用）。
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

    init(report: DiagnosticReport) {
        timestamp = report.date
        statusRaw = report.status.rawValue
        failedStageRaw = report.failedStage?.rawValue
        triggerRaw = report.trigger.rawValue
        interfaceName = report.snapshot.interfaceLabel
        gatewayLatencyMs = report.result(for: .gateway)?.latencyMs
        internetLatencyMs = report.result(for: .internet)?.latencyMs
        dnsLatencyMs = report.result(for: .dns)?.latencyMs
        webLatencyMs = report.result(for: .web)?.latencyMs
    }

    var sample: CheckSample {
        CheckSample(
            timestamp: timestamp,
            status: ConnectivityStatus(rawValue: statusRaw) ?? .offline,
            failedStage: failedStageRaw.flatMap(DiagnosticStage.init(rawValue:)),
            trigger: CheckTrigger(rawValue: triggerRaw) ?? .periodic,
            interface: interfaceName,
            gatewayLatencyMs: gatewayLatencyMs,
            internetLatencyMs: internetLatencyMs,
            dnsLatencyMs: dnsLatencyMs,
            webLatencyMs: webLatencyMs
        )
    }
}

nonisolated enum LogEventKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// インターネットに接続できなくなった
    case outage
    /// 障害中に原因箇所が変わった
    case causeChanged
    /// 接続が復旧した
    case restored

    var id: String { rawValue }

    var label: String {
        switch self {
        case .outage: "接続エラー"
        case .causeChanged: "原因の変化"
        case .restored: "復旧"
        }
    }

    var symbolName: String {
        switch self {
        case .outage: "xmark.octagon.fill"
        case .causeChanged: "arrow.triangle.branch"
        case .restored: "checkmark.circle.fill"
        }
    }
}

/// 接続エラーに関するログ。
@Model
nonisolated final class ErrorLogEntry {
    #Index<ErrorLogEntry>([\.timestamp])

    var timestamp: Date
    var kindRaw: String
    var stageRaw: String?
    var headline: String
    var message: String
    /// 診断レポートのテキスト
    var detail: String
    var interfaceName: String?
    /// 復旧時の停止時間（秒）
    var downtime: Double?
    /// 診断レポートの JSON（エクスポート用）
    var reportJSON: Data?

    init(kind: LogEventKind, report: DiagnosticReport, headline: String, message: String, downtime: Double? = nil) {
        timestamp = report.date
        kindRaw = kind.rawValue
        stageRaw = report.failedStage?.rawValue
        self.headline = headline
        self.message = message
        detail = report.textReport
        interfaceName = report.snapshot.interfaceLabel
        self.downtime = downtime
        reportJSON = try? JSONEncoder().encode(report)
    }

    var kind: LogEventKind { LogEventKind(rawValue: kindRaw) ?? .outage }
    var stage: DiagnosticStage? { stageRaw.flatMap(DiagnosticStage.init(rawValue:)) }

    var snapshot: LogEntrySnapshot {
        LogEntrySnapshot(
            timestamp: timestamp, kind: kind, stage: stage, headline: headline, message: message,
            detail: detail, interface: interfaceName, downtime: downtime,
            report: reportJSON.flatMap { try? JSONDecoder().decode(DiagnosticReport.self, from: $0) }
        )
    }
}

/// スレッド間で受け渡すためのチェック記録の値型。
nonisolated struct CheckSample: Codable, Sendable, Hashable {
    var timestamp: Date
    var status: ConnectivityStatus
    var failedStage: DiagnosticStage?
    var trigger: CheckTrigger
    var interface: String?
    var gatewayLatencyMs: Double?
    var internetLatencyMs: Double?
    var dnsLatencyMs: Double?
    var webLatencyMs: Double?
}

/// スレッド間で受け渡すためのログの値型。
nonisolated struct LogEntrySnapshot: Codable, Sendable {
    var timestamp: Date
    var kind: LogEventKind
    var stage: DiagnosticStage?
    var headline: String
    var message: String
    var detail: String
    var interface: String?
    var downtime: Double?
    var report: DiagnosticReport?
}

/// バックグラウンドでデータを読み書きするアクター。
@ModelActor
actor DataStore {
    func samples(from start: Date?, to end: Date) throws -> [CheckSample] {
        let descriptor: FetchDescriptor<CheckRecord>
        if let start {
            descriptor = FetchDescriptor(predicate: #Predicate { $0.timestamp >= start && $0.timestamp <= end },
                                         sortBy: [SortDescriptor(\.timestamp)])
        } else {
            descriptor = FetchDescriptor(predicate: #Predicate { $0.timestamp <= end },
                                         sortBy: [SortDescriptor(\.timestamp)])
        }
        return try modelContext.fetch(descriptor).map(\.sample)
    }

    func prune(olderThan cutoff: Date) throws {
        try modelContext.delete(model: CheckRecord.self, where: #Predicate { $0.timestamp < cutoff })
        try modelContext.delete(model: ErrorLogEntry.self, where: #Predicate { $0.timestamp < cutoff })
        try modelContext.save()
    }
}
