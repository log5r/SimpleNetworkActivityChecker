import AppKit
import UniformTypeIdentifiers

nonisolated enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv
    case json
    case text

    var id: String { rawValue }

    var contentType: UTType {
        switch self {
        case .csv: .commaSeparatedText
        case .json: .json
        case .text: .plainText
        }
    }

    var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .json: "json"
        case .text: "txt"
        }
    }
}

/// エクスポート用のデータ生成。
nonisolated enum ExportEncoder {
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()

    static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }

    private static func csvField(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        if value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private static func number(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? ""
    }

    private static func csv(header: [String], rows: [[String?]]) -> Data {
        var text = header.map(csvField).joined(separator: ",") + "\r\n"
        for row in rows {
            text += row.map(csvField).joined(separator: ",") + "\r\n"
        }
        // Excel で文字化けしないよう BOM を付ける
        return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
    }

    private static func json(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    // MARK: Statistics

    static func samplesCSV(_ samples: [CheckSample]) -> Data {
        csv(
            header: ["timestamp", "status", "failed_stage", "trigger", "interface",
                     "gateway_ms", "internet_ms", "dns_ms", "web_ms"],
            rows: samples.map {
                [iso($0.timestamp), $0.status.rawValue, $0.failedStage?.rawValue, $0.trigger.rawValue, $0.interface,
                 number($0.gatewayLatencyMs), number($0.internetLatencyMs), number($0.dnsLatencyMs), number($0.webLatencyMs)]
            }
        )
    }

    static func outagesCSV(_ outages: [Outage], now: Date) -> Data {
        csv(
            header: ["start", "end", "duration_seconds", "failed_stage", "failed_checks"],
            rows: outages.map {
                [iso($0.start), $0.end.map(iso), String(Int($0.duration(now: now))), $0.stage.rawValue, String($0.failedChecks)]
            }
        )
    }

    private struct StatisticsDocument: Encodable {
        struct Latency: Encodable { var averageMs: Double?; var p95Ms: Double?; var maxMs: Double? }
        struct Cause: Encodable { var stage: String; var outageCount: Int; var downtimeSeconds: Double }
        struct OutageEntry: Encodable { var start: Date; var end: Date?; var durationSeconds: Double; var failedStage: String; var failedChecks: Int }

        var exportedAt: Date
        var period: String
        var rangeStart: Date?
        var rangeEnd: Date
        var checkCount: Int
        var failedCheckCount: Int
        var degradedCheckCount: Int
        var availabilityPercent: Double?
        var measuredSeconds: Double
        var totalDowntimeSeconds: Double
        var outageCount: Int
        var latency: [String: Latency]
        var causes: [Cause]
        var outages: [OutageEntry]
        var samples: [CheckSample]
    }

    static func statisticsJSON(_ summary: StatisticsSummary, samples: [CheckSample]) throws -> Data {
        func latency(_ value: LatencySummary) -> StatisticsDocument.Latency {
            .init(averageMs: value.average, p95Ms: value.p95, maxMs: value.maximum)
        }
        let document = StatisticsDocument(
            exportedAt: .now,
            period: summary.period.rawValue,
            rangeStart: summary.rangeStart,
            rangeEnd: summary.rangeEnd,
            checkCount: summary.checkCount,
            failedCheckCount: summary.failedCheckCount,
            degradedCheckCount: summary.degradedCheckCount,
            availabilityPercent: summary.availability.map { $0 * 100 },
            measuredSeconds: summary.measuredSeconds,
            totalDowntimeSeconds: summary.totalDowntime,
            outageCount: summary.outages.count,
            latency: ["gateway": latency(summary.gateway), "internet": latency(summary.internet),
                      "dns": latency(summary.dns), "web": latency(summary.web)],
            causes: summary.causes.map { .init(stage: $0.stage.rawValue, outageCount: $0.outageCount, downtimeSeconds: $0.downtime) },
            outages: summary.outages.map {
                .init(start: $0.start, end: $0.end, durationSeconds: $0.duration(now: summary.rangeEnd),
                      failedStage: $0.stage.rawValue, failedChecks: $0.failedChecks)
            },
            samples: samples
        )
        return try json(document)
    }

    // MARK: Logs

    static func logsCSV(_ entries: [LogEntrySnapshot]) -> Data {
        csv(
            header: ["timestamp", "kind", "failed_stage", "headline", "message", "interface", "downtime_seconds", "detail"],
            rows: entries.map {
                [iso($0.timestamp), $0.kind.rawValue, $0.stage?.rawValue, $0.headline, $0.message, $0.interface,
                 $0.downtime.map { String(Int($0)) }, $0.detail]
            }
        )
    }

    static func logsJSON(_ entries: [LogEntrySnapshot]) throws -> Data {
        try json(entries)
    }

    static func logsText(_ entries: [LogEntrySnapshot]) -> Data {
        let separator = "\n" + String(repeating: "=", count: 60) + "\n"
        let text = entries.map { entry in
            "■ \(entry.kind.label)  \(entry.headline)\n\(entry.message)\n\n\(entry.detail)"
        }.joined(separator: separator)
        return Data(text.utf8)
    }
}

/// 保存パネルを表示してファイルを書き出す。
@MainActor
enum Exporter {
    static func export(suggestedName: String, format: ExportFormat,
                       makeData: @escaping @Sendable () throws -> Data) async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(suggestedName).\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let response: NSApplication.ModalResponse = if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            await panel.beginSheetModal(for: window)
        } else {
            await panel.begin()
        }
        guard response == .OK, let url = panel.url else { return }

        do {
            try await Task.detached(priority: .userInitiated) {
                try makeData().write(to: url, options: .atomic)
            }.value
        } catch {
            presentError(error, message: "書き出しに失敗しました")
        }
    }

    static func presentError(_ error: Error, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    static func timestampedName(_ base: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(base)-\(formatter.string(from: .now))"
    }
}
