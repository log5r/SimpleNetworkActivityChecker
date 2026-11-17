import AppKit
import Network
import OSLog
import SwiftData
import UserNotifications

/// 定期的に接続診断を行い、結果を記録する。アプリ全体で 1 つだけ存在する。
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var latestReport: DiagnosticReport?
    private(set) var isChecking = false
    /// 現在の障害の開始時刻（障害中でなければ nil）
    private(set) var outageStart: Date?
    /// 記録が追加・削除されるたびに増える（統計画面の再読み込みに使用）
    private(set) var dataVersion = 0
    /// 保存などで発生したエラー（ユーザーに表示する）
    var persistenceError: String?

    @ObservationIgnored let container: ModelContainer
    @ObservationIgnored private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SimpleNetworkActivityChecker", category: "Monitor")
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var pathChangeTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastPathSignature: String?
    @ObservationIgnored private var pathIsExpensive = false
    @ObservationIgnored private var pathIsConstrained = false
    @ObservationIgnored private var outageStage: DiagnosticStage?
    /// 現在の障害で実際に計測できた停止時間（統計と同じく、チェック間隔が空いた分は上限までしか数えない）
    @ObservationIgnored private var outageDowntime: TimeInterval = 0
    /// 現在の障害中に最後に記録したチェックの時刻
    @ObservationIgnored private var outageLastCheck: Date?
    @ObservationIgnored private var lastPrune: Date?
    @ObservationIgnored private var pruneTask: Task<Void, Error>?
    @ObservationIgnored private var isPruning = false
    @ObservationIgnored private var nextPruneRetry: Date?
    @ObservationIgnored private var hasReportedPruneFailure = false
    @ObservationIgnored private var isSleeping = false
    @ObservationIgnored private var started = false
    /// スリープや停止のたびに増える。実行中のチェックが開始時と異なる世代で終わった場合、その結果は破棄する
    @ObservationIgnored private var checkGeneration = 0
    /// チェック中にネットワークが切り替わったため、終了後にもう一度確認する必要があるか
    @ObservationIgnored private var needsRecheckAfterNetworkChange = false
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []

    private static let outageStartKey = "currentOutageStart"
    private static let outageStageKey = "currentOutageStage"
    private static let outageDowntimeKey = "currentOutageDowntime"
    private static let outageLastCheckKey = "currentOutageLastCheck"

    init(container: ModelContainer) {
        self.container = container
        let defaults = UserDefaults.standard
        if let start = defaults.object(forKey: Self.outageStartKey) as? Date {
            outageStart = start
            outageStage = defaults.string(forKey: Self.outageStageKey).flatMap(DiagnosticStage.init(rawValue:))
            outageDowntime = defaults.double(forKey: Self.outageDowntimeKey)
            outageLastCheck = defaults.object(forKey: Self.outageLastCheckKey) as? Date ?? start
        }
    }

    private var context: ModelContext { container.mainContext }

    /// 現在の総合状態（未確認なら nil）
    var status: ConnectivityStatus? { latestReport?.status }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = "\(path.status)|\(path.availableInterfaces.map(\.name).joined(separator: ","))|\(path.gateways.map(\.debugDescription).joined(separator: ","))"
            // 更新頻度は低いのでメインキューで受け取る
            MainActor.assumeIsolated {
                self?.handlePathChange(signature: signature, expensive: path.isExpensive, constrained: path.isConstrained)
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWillSleep() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDidWake() }
        })

        if AppSettings.notificationsEnabled {
            requestNotificationAuthorization()
        }

        Task { await performCheck(trigger: .launch) }
    }

    func stop() {
        timerTask?.cancel()
        pathChangeTask?.cancel()
        invalidateInFlightCheck()
        pathMonitor?.cancel()
        pathMonitor = nil
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        started = false
    }

    /// ユーザー操作による即時チェック。
    func checkNow() {
        guard !isChecking else { return }
        timerTask?.cancel()
        Task { await performCheck(trigger: .manual) }
    }

    /// 設定変更後にタイマーを掛け直す。
    func reschedule() {
        guard started, !isChecking else { return }
        scheduleNextCheck()
    }

    // MARK: - Checking

    private func scheduleNextCheck(after interval: TimeInterval? = nil, trigger: CheckTrigger = .periodic) {
        timerTask?.cancel()
        let delay = interval ?? (outageStart != nil ? AppSettings.offlineCheckInterval : AppSettings.checkInterval)
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.performCheck(trigger: trigger)
        }
    }

    private func performCheck(trigger: CheckTrigger) async {
        guard !isChecking, !isSleeping else { return }
        let generation = checkGeneration
        isChecking = true
        needsRecheckAfterNetworkChange = false
        // 呼び出し元のタスク（タイマーやネットワーク変更の待機）がキャンセルされても診断が途中で
        // 打ち切られないよう、キャンセルが伝わらない別タスクで実行する（打ち切られると通信失敗＝障害と誤判定される）
        let diagnosis = Task.detached(priority: Task.currentPriority) {
            await NetworkDiagnostician.run(trigger: trigger)
        }
        var report = await diagnosis.value
        // 実行中にスリープ・停止した場合は結果を破棄する（スリープ解除時のタイマーもそのまま残す）
        guard generation == checkGeneration else {
            logger.info("Discarded a check that was interrupted by sleep or stop")
            return
        }
        report.snapshot.isExpensive = pathIsExpensive
        report.snapshot.isConstrained = pathIsConstrained
        isChecking = false

        record(report)
        if needsRecheckAfterNetworkChange {
            // チェック中にネットワークが切り替わったので、切り替わり後の状態を改めて確認する
            needsRecheckAfterNetworkChange = false
            scheduleNextCheck(after: 1, trigger: .networkChange)
        } else {
            scheduleNextCheck()
        }
    }

    /// 実行中のチェックの結果を無効にする。
    private func invalidateInFlightCheck() {
        checkGeneration &+= 1
        isChecking = false
        needsRecheckAfterNetworkChange = false
    }

    private func record(_ report: DiagnosticReport) {
        latestReport = report
        context.insert(CheckRecord(report: report))

        // 統計（StatisticsSummary.compute）と同じ方法で、障害中のチェックから次のチェックまでの時間を
        // 停止時間として積み上げる。スリープ中やアプリが動いていなかった時間は上限までしか数えない。
        if outageStart != nil, let previous = outageLastCheck {
            let span = min(max(0, report.date.timeIntervalSince(previous)), StatisticsSummary.maximumSampleGap)
            outageDowntime += span
        }

        if report.status == .offline {
            let stage = report.failedStage ?? .web
            outageLastCheck = report.date
            if outageStart == nil {
                outageStart = report.date
                outageStage = stage
                outageDowntime = 0
                insertLog(.outage, report: report,
                          headline: "インターネットに接続できなくなりました",
                          message: "\(stage.title)で到達不能: \(report.diagnosis.headline)")
                notify(title: "インターネットに接続できません", body: report.diagnosis.headline)
            } else if outageStage != stage {
                let previous = outageStage?.title ?? "不明"
                outageStage = stage
                insertLog(.causeChanged, report: report,
                          headline: "原因の箇所が変わりました（\(previous) → \(stage.title)）",
                          message: report.diagnosis.headline)
            }
        } else if outageStart != nil {
            let downtime = outageDowntime
            insertLog(.restored, report: report,
                      headline: "インターネット接続が復旧しました",
                      message: "停止時間: \(downtime.durationText)", downtime: downtime)
            notify(title: "インターネット接続が復旧しました", body: "停止時間: \(downtime.durationText)")
            outageStart = nil
            outageStage = nil
            outageDowntime = 0
            outageLastCheck = nil
        }
        persistOutageState()
        save()
        pruneIfNeeded()
    }

    private func insertLog(_ kind: LogEventKind, report: DiagnosticReport, headline: String, message: String, downtime: Double? = nil) {
        context.insert(ErrorLogEntry(kind: kind, report: report, headline: headline, message: message, downtime: downtime))
        logger.notice("\(headline, privacy: .public): \(message, privacy: .public)")
    }

    private func save() {
        do {
            try context.save()
            dataVersion += 1
        } catch {
            logger.error("Failed to save: \(error.localizedDescription, privacy: .public)")
            persistenceError = "記録を保存できませんでした: \(error.localizedDescription)"
        }
    }

    private func persistOutageState() {
        let defaults = UserDefaults.standard
        if let outageStart {
            defaults.set(outageStart, forKey: Self.outageStartKey)
            defaults.set(outageStage?.rawValue, forKey: Self.outageStageKey)
            defaults.set(outageDowntime, forKey: Self.outageDowntimeKey)
            defaults.set(outageLastCheck, forKey: Self.outageLastCheckKey)
        } else {
            for key in [Self.outageStartKey, Self.outageStageKey, Self.outageDowntimeKey, Self.outageLastCheckKey] {
                defaults.removeObject(forKey: key)
            }
        }
    }

    // MARK: - Data management

    /// 前回の削除から時間が経っていれば、保存期間を過ぎた記録をバックグラウンドで削除する。
    private func pruneIfNeeded() {
        guard AppSettings.retentionDays > 0, !isPruning else { return }
        if let lastPrune, Date().timeIntervalSince(lastPrune) < 6 * 3600 { return }
        if let nextPruneRetry, Date() < nextPruneRetry { return }
        Task {
            do {
                try await prune()
            } catch {
                logger.error("Failed to prune: \(error.localizedDescription, privacy: .public)")
                // 少し間を空けて再試行する。エラーは繰り返し表示せず、成功するまでに一度だけ知らせる
                nextPruneRetry = Date().addingTimeInterval(5 * 60)
                if !hasReportedPruneFailure {
                    hasReportedPruneFailure = true
                    persistenceError = "保存期間を過ぎた記録を削除できませんでした: \(error.localizedDescription)"
                }
            }
        }
    }

    /// 保存期間を過ぎた記録を削除する。メインスレッドを塞がないよう、別スレッドのコンテキストで実行する。
    private func prune() async throws {
        let days = AppSettings.retentionDays
        guard days > 0 else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .distantPast
        let container = container
        let previous = pruneTask
        let task = Task.detached(priority: .utility) {
            // 削除処理が重ならないよう、実行中の削除が終わるのを待つ
            _ = await previous?.result
            try await DataStore(modelContainer: container).prune(olderThan: cutoff)
        }
        pruneTask = task
        isPruning = true
        defer {
            if pruneTask == task {
                pruneTask = nil
                isPruning = false
            }
        }
        try await task.value
        lastPrune = .now
        nextPruneRetry = nil
        hasReportedPruneFailure = false
        // 統計画面などを再読み込みさせる
        dataVersion += 1
    }

    /// 保存期間の変更を即座に反映する。削除に失敗した場合はエラーを投げる（次回のチェック時にも再試行される）。
    func applyRetentionPolicy() async throws {
        try await prune()
    }

    func deleteAllStatistics() throws {
        try context.delete(model: CheckRecord.self)
        try context.save()
        dataVersion += 1
    }

    func deleteAllLogs() throws {
        try context.delete(model: ErrorLogEntry.self)
        try context.save()
        dataVersion += 1
    }

    // MARK: - Events

    private func handlePathChange(signature: String, expensive: Bool, constrained: Bool) {
        pathIsExpensive = expensive
        pathIsConstrained = constrained
        defer { lastPathSignature = signature }
        guard let previous = lastPathSignature, previous != signature else { return }

        // 接続の切り替わり直後は不安定なので少し待ってから確認する
        // （実行中のチェックはこのキャンセルの影響を受けない。performCheck を参照）
        pathChangeTask?.cancel()
        pathChangeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, !self.isSleeping else { return }
            if self.isChecking {
                // 実行中のチェックは切り替わり前の状態を見ている可能性があるため、終わった後で改めて確認する
                self.needsRecheckAfterNetworkChange = true
                return
            }
            self.timerTask?.cancel()
            await self.performCheck(trigger: .networkChange)
        }
    }

    private func handleWillSleep() {
        isSleeping = true
        timerTask?.cancel()
        pathChangeTask?.cancel()
        // スリープをまたいだチェックは通信がタイムアウトして障害と誤判定されるため、結果を破棄する
        invalidateInFlightCheck()
    }

    private func handleDidWake() {
        isSleeping = false
        // スリープ解除直後はネットワークの再接続に時間がかかるため待ってから確認する
        scheduleNextCheck(after: 15, trigger: .wake)
    }

    // MARK: - Notifications

    func requestNotificationAuthorization() {
        Task {
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            } catch {
                logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func notify(title: String, body: String) {
        guard AppSettings.notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [logger] error in
            if let error { logger.error("Failed to post notification: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
