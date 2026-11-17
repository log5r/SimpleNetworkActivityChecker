import Foundation
import Testing
@testable import SimpleNetworkActivityChecker

/// スリープ（監視の中断）をまたいだ時間を停止時間に数えないことの確認。
struct DowntimeTests {
    private let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { origin.addingTimeInterval(seconds) }

    private func sample(_ seconds: TimeInterval, _ status: ConnectivityStatus,
                        stage: DiagnosticStage? = nil, pausedAt: TimeInterval? = nil) -> CheckSample {
        CheckSample(timestamp: at(seconds), status: status, failedStage: stage ?? (status == .offline ? .internet : nil),
                    trigger: .periodic, monitoringPausedAt: pausedAt.map(at))
    }

    // MARK: observedSpan

    @Test func spanStopsAtPause() {
        #expect(StatisticsSummary.observedSpan(from: at(0), to: at(3_600), monitoringPausedAt: at(10)) == 10)
        #expect(StatisticsSummary.observedSpan(from: at(0), to: at(30), monitoringPausedAt: nil) == 30)
        // 中断がチェックより前（ありえないが）なら何も数えない
        #expect(StatisticsSummary.observedSpan(from: at(100), to: at(200), monitoringPausedAt: at(50)) == 0)
        // 中断の記録がない空白は従来どおり上限まで
        #expect(StatisticsSummary.observedSpan(from: at(0), to: at(3_600), monitoringPausedAt: nil) == StatisticsSummary.maximumSampleGap)
    }

    // MARK: Statistics

    /// オフラインのチェックの直後にスリープし、スリープ解除後にオンラインになった場合、スリープ中の時間は停止時間に含めない。
    @Test func statisticsExcludeSleepAfterOfflineSample() {
        let samples = [
            sample(0, .online),
            sample(60, .offline),                     // 70 秒の時点でスリープ
            sample(3_675, .online, pausedAt: 70),     // 1 時間後に解除してチェック
        ]
        let summary = StatisticsSummary.compute(samples: samples, period: .all, now: at(3_735))

        #expect(summary.outages.count == 1)
        #expect(summary.outages.first?.downtime == 10)
        #expect(summary.totalDowntime == 10)
        #expect(summary.causes.first?.downtime == 10)
        #expect(summary.measuredSeconds == 60 + 10 + 60)
        #expect(summary.upSeconds == 120)
        #expect(summary.buckets.reduce(0) { $0 + $1.downSeconds } == 10)
    }

    /// まだ次のチェックを記録していない中断（スリープ解除直後など）も数えない。
    @Test func statisticsExcludeCurrentPause() {
        let samples = [sample(0, .offline)]
        let paused = StatisticsSummary.compute(samples: samples, period: .all, now: at(3_600), monitoringPausedSince: at(20))
        #expect(paused.totalDowntime == 20)

        let running = StatisticsSummary.compute(samples: samples, period: .all, now: at(30))
        #expect(running.totalDowntime == 30)
    }

    // MARK: Live accumulation

    @Test func liveDowntimeExcludesSleepAfterOfflineSample() {
        var tracker = OutageTracker()
        #expect(tracker.record(date: at(0), status: .online, failedStage: nil, monitoringPausedAt: nil) == nil)
        #expect(tracker.record(date: at(60), status: .offline, failedStage: .internet, monitoringPausedAt: nil)
                == .began(stage: .internet))
        // 70 秒の時点でスリープし、1 時間後に解除してオンライン
        #expect(tracker.record(date: at(3_675), status: .online, failedStage: nil, monitoringPausedAt: at(70))
                == .restored(downtime: 10))
        #expect(tracker == OutageTracker())
    }

    @Test func liveDowntimeAcrossSleepWhileStillOffline() {
        var tracker = OutageTracker()
        _ = tracker.record(date: at(0), status: .offline, failedStage: .gateway, monitoringPausedAt: nil)
        _ = tracker.record(date: at(30), status: .offline, failedStage: .gateway, monitoringPausedAt: nil)
        // 40 秒の時点でスリープし、解除後もオフライン（原因の箇所が変わった）
        #expect(tracker.record(date: at(5_000), status: .offline, failedStage: .internet, monitoringPausedAt: at(40))
                == .causeChanged(from: .gateway, to: .internet))
        #expect(tracker.downtime == 40)
        #expect(tracker.record(date: at(5_030), status: .online, failedStage: nil, monitoringPausedAt: nil)
                == .restored(downtime: 70))
    }

    /// 復旧ログ・通知の停止時間と統計の停止時間が一致する。
    @Test func liveAndStatisticsAgree() {
        let samples = [
            sample(0, .online),
            sample(60, .offline, stage: .gateway),
            sample(90, .offline, stage: .gateway),
            sample(4_000, .offline, stage: .dns, pausedAt: 100),
            sample(4_020, .offline, stage: .dns),
            sample(9_000, .online, pausedAt: 4_025),
            sample(9_060, .online),
        ]
        var tracker = OutageTracker()
        var restored: [TimeInterval] = []
        for sample in samples {
            if case .restored(let downtime) = tracker.record(date: sample.timestamp, status: sample.status,
                                                             failedStage: sample.failedStage,
                                                             monitoringPausedAt: sample.monitoringPausedAt) {
                restored.append(downtime)
            }
        }
        let summary = StatisticsSummary.compute(samples: samples, period: .all, now: at(9_120))
        #expect(restored == [30 + 10 + 20 + 5])
        #expect(summary.outages.map(\.downtime) == restored)
    }
}
