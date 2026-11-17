import Charts
import SwiftData
import SwiftUI

/// 接続可否の統計。
struct StatisticsView: View {
    @Environment(NetworkMonitor.self) private var monitor
    @AppStorage("statisticsPeriod") private var period: StatisticsPeriod = .day
    @State private var summary: StatisticsSummary?
    @State private var samples: [CheckSample] = []
    @State private var loadError: String?
    /// 最後に読み込みを終えた時刻（記録の追加による再読み込みの間隔を空けるために使う）
    @State private var lastLoaded: Date?

    private struct LoadKey: Equatable {
        var period: StatisticsPeriod
        var version: Int
    }

    /// 記録が追加されたときに再読み込みする最短の間隔（秒）。期間が長いほど読み込みが重いので間隔を空ける。
    private var reloadInterval: TimeInterval {
        switch period {
        case .day: 5
        case .week: 15
        case .month, .all: 60
        }
    }

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView {
                    Label("統計を読み込めません", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("再試行") { Task { await load() } }
                }
            } else if let summary, summary.period == period, summary.checkCount > 0 {
                content(summary)
            } else if let summary, summary.period == period {
                ContentUnavailableView("この期間のデータはありません", systemImage: "chart.bar",
                                       description: Text("アプリが起動している間、接続状態が定期的に記録されます。"))
            } else {
                ProgressView("読み込み中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("統計")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("期間", selection: $period) {
                    ForEach(StatisticsPeriod.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("集計する期間")
            }
            ToolbarItem {
                Menu {
                    Button("チェック履歴を CSV で書き出す…") { exportSamplesCSV() }
                    Button("障害の一覧を CSV で書き出す…") { exportOutagesCSV() }
                    Divider()
                    Button("統計サマリーと履歴を JSON で書き出す…") { exportJSON() }
                } label: {
                    Label("書き出す", systemImage: "square.and.arrow.up")
                }
                .disabled(samples.isEmpty || summary?.period != period)
                .help("統計データをファイルに書き出します")
            }
        }
        .task(id: LoadKey(period: period, version: monitor.dataVersion)) {
            await reload()
        }
    }

    /// 期間を切り替えたときはすぐに、記録が追加されたときは間隔を空けてから読み込み直す。
    /// 待っている間に次の記録が追加されると .task(id:) が作り直され、この待機はキャンセルされる。
    private func reload() async {
        if summary?.period == period, loadError == nil, let lastLoaded {
            let wait = reloadInterval - Date().timeIntervalSince(lastLoaded)
            if wait > 0 {
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            }
        }
        await load()
    }

    private func load() async {
        let period = period
        let now = Date()
        let container = monitor.container
        // メインスレッドを塞がないよう、別スレッドのコンテキストで読み込んで集計する
        let work = Task.detached(priority: .userInitiated) {
            let store = DataStore(modelContainer: container)
            let samples = try await store.samples(from: period.startDate(relativeTo: now), to: now)
            try Task.checkCancellation()
            return (samples, StatisticsSummary.compute(samples: samples, period: period, now: now))
        }
        do {
            // 画面の再読み込みでこのタスクがキャンセルされたら、読み込み処理にも伝えて重複して動かないようにする
            let result = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled else { return }
            samples = result.0
            summary = result.1
            loadError = nil
            lastLoaded = .now
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
    }

    // MARK: - Content

    private func content(_ summary: StatisticsSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                tiles(summary)
                ChartSection(title: "稼働率の推移", subtitle: summary.period.bucketComponent == .hour ? "1 時間ごと" : "1 日ごと") {
                    AvailabilityChart(buckets: summary.buckets, unit: summary.period.bucketComponent)
                }
                ChartSection(title: "応答時間の推移", subtitle: "平均（ミリ秒）") {
                    LatencyChart(buckets: summary.buckets, unit: summary.period.bucketComponent)
                }
                HStack(alignment: .top, spacing: 20) {
                    ChartSection(title: "障害の原因（途切れた箇所）", subtitle: "\(summary.outages.count) 回") {
                        CauseChart(causes: summary.causes)
                    }
                    ChartSection(title: "応答時間の詳細", subtitle: "平均 / 95 パーセンタイル / 最大") {
                        LatencyTable(summary: summary)
                    }
                }
                ChartSection(title: "障害の履歴", subtitle: "インターネットに接続できなかった期間（停止時間は計測できた時間のみ）") {
                    OutageList(outages: summary.outages.reversed())
                }
            }
            .padding(20)
        }
    }

    private func tiles(_ summary: StatisticsSummary) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            StatTile(title: "稼働率",
                     value: summary.availability.map { $0.formatted(.percent.precision(.fractionLength(2))) } ?? "—",
                     detail: "計測時間 \(summary.measuredSeconds.durationText)",
                     color: (summary.availability ?? 1) >= 0.99 ? .green : (summary.availability ?? 1) >= 0.95 ? .orange : .red)
            StatTile(title: "障害の回数", value: "\(summary.outages.count) 回",
                     detail: "失敗したチェック \(summary.failedCheckCount) 回",
                     color: summary.outages.isEmpty ? .green : .red)
            StatTile(title: "合計停止時間", value: summary.totalDowntime.durationText,
                     detail: summary.longestOutage.map { "最長 \($0.downtime.durationText)" } ?? "障害なし",
                     color: summary.totalDowntime > 0 ? .red : .green)
            StatTile(title: "インターネット応答", value: summary.internet.average.map { String(format: "%.0f ms", $0) } ?? "—",
                     detail: "平均（TCP 接続時間）", color: .accentColor)
            StatTile(title: "チェック回数", value: "\(summary.checkCount) 回",
                     detail: summary.degradedCheckCount > 0 ? "一部に問題あり \(summary.degradedCheckCount) 回" : "記録開始 \(summary.firstSample?.formatted(date: .abbreviated, time: .shortened) ?? "—")",
                     color: .secondary)
        }
    }

    // MARK: - Export

    private var exportBaseName: String { "network-\(period.rawValue)" }

    private func exportSamplesCSV() {
        let samples = samples
        Task {
            await Exporter.export(suggestedName: Exporter.timestampedName("\(exportBaseName)-checks"), format: .csv) {
                ExportEncoder.samplesCSV(samples)
            }
        }
    }

    private func exportOutagesCSV() {
        guard let summary else { return }
        let outages = summary.outages
        Task {
            await Exporter.export(suggestedName: Exporter.timestampedName("\(exportBaseName)-outages"), format: .csv) {
                ExportEncoder.outagesCSV(outages)
            }
        }
    }

    private func exportJSON() {
        guard let summary else { return }
        let samples = samples
        Task {
            await Exporter.export(suggestedName: Exporter.timestampedName("\(exportBaseName)-statistics"), format: .json) {
                try ExportEncoder.statisticsJSON(summary, samples: samples)
            }
        }
    }
}

// MARK: - Components

private struct StatTile: View {
    var title: String
    var value: String
    var detail: String
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(color == .secondary ? .primary : color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct ChartSection<Content: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox {
            content
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct AvailabilityChart: View {
    var buckets: [StatisticsBucket]
    var unit: Calendar.Component

    var body: some View {
        Chart(buckets) { bucket in
            if let availability = bucket.availability {
                BarMark(x: .value("時刻", bucket.start, unit: unit),
                        y: .value("稼働率", availability * 100))
                    .foregroundStyle(availability >= 0.999 ? Color.green : availability >= 0.95 ? .orange : .red)
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 90, 100]) { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)%") } }
            }
        }
        .frame(height: 180)
        .accessibilityLabel("稼働率の推移")
    }
}

private struct LatencyChart: View {
    var buckets: [StatisticsBucket]
    var unit: Calendar.Component

    private struct Point: Identifiable {
        var date: Date
        var series: String
        var value: Double
        var id: String { "\(series)-\(date.timeIntervalSince1970)" }
    }

    private var points: [Point] {
        buckets.flatMap { bucket -> [Point] in
            [("ルーター", bucket.gatewayLatency), ("インターネット", bucket.internetLatency),
             ("DNS", bucket.dnsLatency), ("Web", bucket.webLatency)]
                .compactMap { name, value in value.map { Point(date: bucket.start, series: name, value: $0) } }
        }
    }

    var body: some View {
        Chart(points) { point in
            LineMark(x: .value("時刻", point.date, unit: unit), y: .value("応答時間 (ms)", point.value))
                .foregroundStyle(by: .value("項目", point.series))
                .interpolationMethod(.monotone)
            PointMark(x: .value("時刻", point.date, unit: unit), y: .value("応答時間 (ms)", point.value))
                .foregroundStyle(by: .value("項目", point.series))
                .symbolSize(buckets.count > 40 ? 0 : 16)
        }
        .chartForegroundStyleScale(["ルーター": Color.teal, "インターネット": Color.blue, "DNS": Color.purple, "Web": Color.orange])
        .chartLegend(position: .top, alignment: .leading)
        .frame(height: 200)
        .accessibilityLabel("応答時間の推移")
    }
}

private struct CauseChart: View {
    var causes: [CauseStatistic]

    var body: some View {
        if causes.isEmpty {
            Label("この期間に障害はありません", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            Chart(causes) { cause in
                BarMark(x: .value("回数", cause.outageCount), y: .value("箇所", cause.stage.title))
                    .foregroundStyle(.red.gradient)
                    .annotation(position: .trailing) {
                        Text("\(cause.outageCount) 回 / \(cause.downtime.durationText)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
            }
            .chartXAxis(.hidden)
            .frame(height: CGFloat(max(causes.count, 2)) * 36)
        }
    }
}

private struct LatencyTable: View {
    var summary: StatisticsSummary

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                Text("平均"); Text("95%"); Text("最大")
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            Divider()
            row("ルーター", summary.gateway)
            row("インターネット", summary.internet)
            row("DNS", summary.dns)
            row("Web", summary.web)
        }
        .font(.callout.monospacedDigit())
    }

    private func row(_ title: String, _ value: LatencySummary) -> some View {
        GridRow {
            Text(title)
            Text(format(value.average))
            Text(format(value.p95))
            Text(format(value.maximum))
        }
    }

    private func format(_ value: Double?) -> String {
        value.map { String(format: "%.1f ms", $0) } ?? "—"
    }
}

private struct OutageList: View {
    var outages: [Outage]

    var body: some View {
        if outages.isEmpty {
            Label("この期間に障害はありません", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            Table(outages) {
                TableColumn("開始") { Text($0.start.formatted(date: .abbreviated, time: .standard)) }
                TableColumn("復旧") { outage in
                    if let end = outage.end {
                        Text(end.formatted(date: .abbreviated, time: .standard))
                    } else {
                        Text("継続中").foregroundStyle(.red)
                    }
                }
                TableColumn("停止時間") { Text($0.downtime.durationText).monospacedDigit() }
                TableColumn("途切れた箇所") { outage in
                    Label(outage.stage.title, systemImage: outage.stage.symbolName)
                }
            }
            .frame(minHeight: 160, idealHeight: min(CGFloat(outages.count) * 28 + 32, 320))
        }
    }
}
