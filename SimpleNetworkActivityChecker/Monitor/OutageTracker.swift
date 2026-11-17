import Foundation

/// 進行中の障害（オフラインのチェックが続いている間）の状態と、その停止時間の積算。
/// 停止時間は統計（`StatisticsSummary.compute`）と同じ規則（`StatisticsSummary.observedSpan`）で数えるため、
/// 復旧時のログ・通知の停止時間と統計の停止時間は一致し、スリープ中やアプリの終了中の時間は含まれない。
nonisolated struct OutageTracker: Sendable, Equatable {
    /// 障害の開始時刻（障害中でなければ nil）
    var start: Date?
    var stage: DiagnosticStage?
    /// 実際に計測できた停止時間
    var downtime: TimeInterval = 0
    /// 障害中に最後に記録したチェックの時刻
    var lastCheck: Date?

    enum Event: Sendable, Equatable {
        /// 障害が始まった
        case began(stage: DiagnosticStage)
        /// 障害中に原因の箇所が変わった
        case causeChanged(from: DiagnosticStage?, to: DiagnosticStage)
        /// 障害から復旧した
        case restored(downtime: TimeInterval)
    }

    /// チェックの結果を反映し、ログや通知が必要な出来事があれば返す。
    /// - Parameter monitoringPausedAt: 前回のチェックの後で監視が中断された時刻（スリープ・アプリの終了）。
    ///   中断以降の時間は停止時間に数えない。
    mutating func record(date: Date, status: ConnectivityStatus, failedStage: DiagnosticStage?,
                         monitoringPausedAt: Date?) -> Event? {
        if start != nil, let lastCheck {
            downtime += StatisticsSummary.observedSpan(from: lastCheck, to: date, monitoringPausedAt: monitoringPausedAt)
        }

        if status == .offline {
            let newStage = failedStage ?? .web
            lastCheck = date
            if start == nil {
                start = date
                stage = newStage
                downtime = 0
                return .began(stage: newStage)
            }
            guard stage != newStage else { return nil }
            let previous = stage
            stage = newStage
            return .causeChanged(from: previous, to: newStage)
        }

        guard start != nil else { return nil }
        let total = downtime
        self = OutageTracker()
        return .restored(downtime: total)
    }
}
