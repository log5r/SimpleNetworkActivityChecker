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
    @ObservationIgnored private var lastPrune: Date?
    @ObservationIgnored private var isSleeping = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []

    private static let outageStartKey = "currentOutageStart"
    private static let outageStageKey = "currentOutageStage"

    init(container: ModelContainer) {
        self.container = container
        let defaults = UserDefaults.standard
        if let start = defaults.object(forKey: Self.outageStartKey) as? Date {
            outageStart = start
            outageStage = defaults.string(forKey: Self.outageStageKey).flatMap(DiagnosticStage.init(rawValue:))
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
        isChecking = true
        var report = await NetworkDiagnostician.run(trigger: trigger)
        report.snapshot.isExpensive = pathIsExpensive
        report.snapshot.isConstrained = pathIsConstrained
        isChecking = false

        record(report)
        scheduleNextCheck()
    }

    private func record(_ report: DiagnosticReport) {
        latestReport = report
        context.insert(CheckRecord(report: report))

        if report.status == .offline {
            let stage = report.failedStage ?? .web
            if outageStart == nil {
                outageStart = report.date
                outageStage = stage
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
        } else if let start = outageStart {
            let downtime = report.date.timeIntervalSince(start)
            insertLog(.restored, report: report,
                      headline: "インターネット接続が復旧しました",
                      message: "停止時間: \(downtime.durationText)", downtime: downtime)
            notify(title: "インターネット接続が復旧しました", body: "停止時間: \(downtime.durationText)")
            outageStart = nil
            outageStage = nil
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
        } else {
            defaults.removeObject(forKey: Self.outageStartKey)
            defaults.removeObject(forKey: Self.outageStageKey)
        }
    }

    // MARK: - Data management

    private func pruneIfNeeded() {
        let days = AppSettings.retentionDays
        guard days > 0 else { return }
        if let lastPrune, Date().timeIntervalSince(lastPrune) < 6 * 3600 { return }
        lastPrune = Date()
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .distantPast
        do {
            try context.delete(model: CheckRecord.self, where: #Predicate { $0.timestamp < cutoff })
            try context.delete(model: ErrorLogEntry.self, where: #Predicate { $0.timestamp < cutoff })
            try context.save()
        } catch {
            logger.error("Failed to prune: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 保持期間の変更を即座に反映する。
    func applyRetentionPolicy() {
        lastPrune = nil
        pruneIfNeeded()
        dataVersion += 1
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
        pathChangeTask?.cancel()
        pathChangeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, !self.isChecking else { return }
            self.timerTask?.cancel()
            await self.performCheck(trigger: .networkChange)
        }
    }

    private func handleWillSleep() {
        isSleeping = true
        timerTask?.cancel()
        pathChangeTask?.cancel()
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
