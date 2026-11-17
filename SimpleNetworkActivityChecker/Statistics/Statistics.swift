import Foundation

nonisolated enum StatisticsPeriod: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: "24 時間"
        case .week: "7 日間"
        case .month: "30 日間"
        case .all: "全期間"
        }
    }

    func startDate(relativeTo now: Date) -> Date? {
        switch self {
        case .day: now.addingTimeInterval(-24 * 3600)
        case .week: now.addingTimeInterval(-7 * 24 * 3600)
        case .month: now.addingTimeInterval(-30 * 24 * 3600)
        case .all: nil
        }
    }

    /// グラフの集計単位
    var bucketComponent: Calendar.Component {
        switch self {
        case .day: .hour
        case .week, .month, .all: .day
        }
    }
}

nonisolated struct Outage: Identifiable, Sendable, Codable, Hashable {
    var start: Date
    /// 復旧した時刻（継続中なら nil）
    var end: Date?
    var stage: DiagnosticStage
    var failedChecks: Int
    /// 実際に計測できた停止時間。スリープ中やアプリが動いていなかった時間は
    /// `StatisticsSummary.maximumSampleGap` までしか数えないため、`end - start` より短くなることがある。
    var downtime: TimeInterval = 0

    var id: Date { start }
}

nonisolated struct StatisticsBucket: Identifiable, Sendable, Hashable {
    var start: Date
    var upSeconds: Double = 0
    var downSeconds: Double = 0
    var checkCount = 0
    var failedCount = 0
    var gatewayLatency: Double?
    var internetLatency: Double?
    var dnsLatency: Double?
    var webLatency: Double?

    var id: Date { start }

    var availability: Double? {
        let total = upSeconds + downSeconds
        return total > 0 ? upSeconds / total : nil
    }
}

nonisolated struct CauseStatistic: Identifiable, Sendable, Hashable {
    var stage: DiagnosticStage
    var outageCount: Int
    var downtime: TimeInterval
    var id: DiagnosticStage { stage }
}

nonisolated struct LatencySummary: Sendable, Hashable {
    var average: Double?
    var p95: Double?
    var maximum: Double?

    init(_ values: [Double]) {
        guard !values.isEmpty else { return }
        let sorted = values.sorted()
        average = values.reduce(0, +) / Double(values.count)
        p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.down)))]
        maximum = sorted.last
    }
}

nonisolated struct StatisticsSummary: Sendable {
    var period: StatisticsPeriod
    var rangeStart: Date?
    var rangeEnd: Date
    var firstSample: Date?
    var checkCount = 0
    var failedCheckCount = 0
    var degradedCheckCount = 0
    var measuredSeconds: Double = 0
    var upSeconds: Double = 0
    var outages: [Outage] = []
    var buckets: [StatisticsBucket] = []
    var causes: [CauseStatistic] = []
    var gateway = LatencySummary([])
    var internet = LatencySummary([])
    var dns = LatencySummary([])
    var web = LatencySummary([])

    var availability: Double? { measuredSeconds > 0 ? upSeconds / measuredSeconds : nil }
    /// 合計停止時間（計測時間のうち停止していた分。計測時間を超えることはない）
    var totalDowntime: TimeInterval { outages.reduce(0) { $0 + $1.downtime } }
    var longestOutage: Outage? { outages.max { $0.downtime < $1.downtime } }

    /// アプリが動いていなかった時間（スリープ中・終了中）を稼働・停止のどちらにも数えないための上限。
    /// 障害の停止時間（NetworkMonitor の復旧ログ・通知）もこの上限で同じように数える。
    static let maximumSampleGap: TimeInterval = 15 * 60

    static func compute(samples: [CheckSample], period: StatisticsPeriod, now: Date, calendar: Calendar = .current) -> StatisticsSummary {
        var summary = StatisticsSummary(period: period, rangeStart: period.startDate(relativeTo: now), rangeEnd: now)
        summary.firstSample = samples.first?.timestamp
        summary.checkCount = samples.count
        guard !samples.isEmpty else { return summary }

        var bucketMap: [Date: StatisticsBucket] = [:]
        var latencyLists: [Date: (g: [Double], i: [Double], d: [Double], w: [Double])] = [:]
        var allGateway: [Double] = [], allInternet: [Double] = [], allDNS: [Double] = [], allWeb: [Double] = []
        var currentOutage: Outage?

        for (index, sample) in samples.enumerated() {
            let next = index + 1 < samples.count ? samples[index + 1].timestamp : now
            let span = min(max(0, next.timeIntervalSince(sample.timestamp)), maximumSampleGap)
            let bucketStart = calendar.dateInterval(of: period.bucketComponent, for: sample.timestamp)?.start ?? sample.timestamp
            var bucket = bucketMap[bucketStart] ?? StatisticsBucket(start: bucketStart)
            var lists = latencyLists[bucketStart] ?? ([], [], [], [])

            bucket.checkCount += 1
            summary.measuredSeconds += span
            if sample.status.isUp {
                summary.upSeconds += span
                bucket.upSeconds += span
            } else {
                bucket.downSeconds += span
                bucket.failedCount += 1
                summary.failedCheckCount += 1
            }
            if sample.status == .degraded { summary.degradedCheckCount += 1 }

            if let v = sample.gatewayLatencyMs { lists.g.append(v); allGateway.append(v) }
            if let v = sample.internetLatencyMs { lists.i.append(v); allInternet.append(v) }
            if let v = sample.dnsLatencyMs { lists.d.append(v); allDNS.append(v) }
            if let v = sample.webLatencyMs { lists.w.append(v); allWeb.append(v) }

            bucketMap[bucketStart] = bucket
            latencyLists[bucketStart] = lists

            // 連続した失敗を 1 回の障害としてまとめる（停止時間は稼働率と同じく計測できた時間だけを数える）
            if sample.status == .offline {
                if currentOutage == nil {
                    currentOutage = Outage(start: sample.timestamp, end: nil, stage: sample.failedStage ?? .web, failedChecks: 0)
                }
                currentOutage?.failedChecks += 1
                currentOutage?.downtime += span
            } else if var outage = currentOutage {
                outage.end = sample.timestamp
                summary.outages.append(outage)
                currentOutage = nil
            }
        }
        if let currentOutage { summary.outages.append(currentOutage) }

        func average(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        summary.buckets = bucketMap.values.sorted { $0.start < $1.start }.map { bucket in
            var bucket = bucket
            if let lists = latencyLists[bucket.start] {
                bucket.gatewayLatency = average(lists.g)
                bucket.internetLatency = average(lists.i)
                bucket.dnsLatency = average(lists.d)
                bucket.webLatency = average(lists.w)
            }
            return bucket
        }

        summary.gateway = LatencySummary(allGateway)
        summary.internet = LatencySummary(allInternet)
        summary.dns = LatencySummary(allDNS)
        summary.web = LatencySummary(allWeb)

        var causeMap: [DiagnosticStage: CauseStatistic] = [:]
        for outage in summary.outages {
            var cause = causeMap[outage.stage] ?? CauseStatistic(stage: outage.stage, outageCount: 0, downtime: 0)
            cause.outageCount += 1
            cause.downtime += outage.downtime
            causeMap[outage.stage] = cause
        }
        summary.causes = DiagnosticStage.allCases.compactMap { causeMap[$0] }
        return summary
    }
}
