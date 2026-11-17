import AppKit
import SwiftData
import SwiftUI

/// 接続エラーのログ。
struct LogView: View {
    @Environment(NetworkMonitor.self) private var monitor
    @Query(sort: \ErrorLogEntry.timestamp, order: .reverse) private var entries: [ErrorLogEntry]
    @State private var selection: PersistentIdentifier?
    @State private var searchText = ""
    @State private var kindFilter: LogEventKind?
    @State private var isConfirmingDelete = false

    private var filteredEntries: [ErrorLogEntry] {
        entries.filter { entry in
            if let kindFilter, entry.kind != kindFilter { return false }
            guard !searchText.isEmpty else { return true }
            return entry.headline.localizedStandardContains(searchText)
                || entry.message.localizedStandardContains(searchText)
                || entry.detail.localizedStandardContains(searchText)
        }
    }

    var body: some View {
        let filtered = filteredEntries
        Group {
            if entries.isEmpty {
                ContentUnavailableView("エラーログはありません", systemImage: "checkmark.seal",
                                       description: Text("インターネットに接続できなくなると、その時点の診断結果がここに記録されます。"))
            } else {
                VSplitView {
                    table(filtered)
                        .frame(minHeight: 160, idealHeight: 260)
                    detail
                        .frame(minHeight: 200, idealHeight: 360)
                }
            }
        }
        .navigationTitle("エラーログ")
        .navigationSubtitle(entries.isEmpty ? "" : "\(filtered.count) 件")
        .searchable(text: $searchText, prompt: "ログを検索")
        .toolbar {
            ToolbarItemGroup {
                Picker("種類", selection: $kindFilter) {
                    Text("すべての種類").tag(LogEventKind?.none)
                    Divider()
                    ForEach(LogEventKind.allCases) { kind in
                        Label(kind.label, systemImage: kind.symbolName).tag(LogEventKind?.some(kind))
                    }
                }
                .pickerStyle(.menu)
                .help("表示するログの種類")

                Menu {
                    Button("CSV で書き出す…") { export(filtered, as: .csv) }
                    Button("JSON で書き出す…") { export(filtered, as: .json) }
                    Button("テキストで書き出す…") { export(filtered, as: .text) }
                } label: {
                    Label("書き出す", systemImage: "square.and.arrow.up")
                }
                .disabled(filtered.isEmpty)
                .help("表示中のログをファイルに書き出します")

                Button("ログを消去…", systemImage: "trash") { isConfirmingDelete = true }
                    .disabled(entries.isEmpty)
                    .help("すべてのエラーログを削除します")
            }
        }
        .confirmationDialog("すべてのエラーログを削除しますか？", isPresented: $isConfirmingDelete) {
            Button("削除", role: .destructive) {
                do {
                    selection = nil
                    try monitor.deleteAllLogs()
                } catch {
                    Exporter.presentError(error, message: "ログを削除できませんでした")
                }
            }
        } message: {
            Text("この操作は取り消せません。必要な場合は先に書き出してください。")
        }
    }

    private func table(_ rows: [ErrorLogEntry]) -> some View {
        Table(rows, selection: $selection) {
            TableColumn("日時") { entry in
                Text(entry.timestamp.formatted(date: .numeric, time: .standard)).monospacedDigit()
            }
            .width(min: 140, ideal: 160)
            TableColumn("種類") { entry in
                Label(entry.kind.label, systemImage: entry.kind.symbolName)
                    .foregroundStyle(entry.kind.color)
            }
            .width(min: 90, ideal: 110)
            TableColumn("途切れた箇所") { entry in
                Text(entry.stage?.title ?? "—")
            }
            .width(min: 80, ideal: 110)
            TableColumn("内容") { entry in
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.headline)
                    Text(entry.message).font(.caption).foregroundStyle(.secondary)
                }
            }
            TableColumn("停止時間") { entry in
                Text(entry.downtime?.durationText ?? "").monospacedDigit()
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: PersistentIdentifier.self) { ids in
            if let id = ids.first, let entry = entries.first(where: { $0.persistentModelID == id }) {
                Button("診断結果をコピー") { copy(entry) }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection, let entry = entries.first(where: { $0.persistentModelID == selection }) {
            LogDetailView(entry: entry, onCopy: { copy(entry) })
        } else {
            ContentUnavailableView("ログを選択してください", systemImage: "sidebar.squares.right",
                                   description: Text("選択したログの診断結果を表示します。"))
        }
    }

    private func copy(_ entry: ErrorLogEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(entry.headline)\n\(entry.message)\n\n\(entry.detail)", forType: .string)
    }

    private func export(_ rows: [ErrorLogEntry], as format: ExportFormat) {
        let snapshots = rows.map(\.snapshot)
        Task {
            await Exporter.export(suggestedName: Exporter.timestampedName("network-error-log"), format: format) {
                switch format {
                case .csv: ExportEncoder.logsCSV(snapshots)
                case .json: try ExportEncoder.logsJSON(snapshots)
                case .text: ExportEncoder.logsText(snapshots)
                }
            }
        }
    }
}

private struct LogDetailView: View {
    var entry: ErrorLogEntry
    var onCopy: () -> Void

    private var report: DiagnosticReport? {
        entry.reportJSON.flatMap { try? JSONDecoder().decode(DiagnosticReport.self, from: $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.headline).font(.headline)
                            Text(entry.message).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: entry.kind.symbolName).foregroundStyle(entry.kind.color).font(.title2)
                    }
                    Spacer()
                    Button("コピー", systemImage: "doc.on.doc", action: onCopy)
                        .help("診断結果をクリップボードにコピーします")
                }
                if let report {
                    ReachabilityChainView(report: report)
                        .padding(12)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                }
                Text(entry.detail)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
    }
}
