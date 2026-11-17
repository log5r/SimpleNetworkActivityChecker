import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(NetworkMonitor.self) private var monitor
    @AppStorage(AppSettings.checkIntervalKey) private var checkInterval = AppSettings.defaultCheckInterval
    @AppStorage(AppSettings.retentionDaysKey) private var retentionDays = AppSettings.defaultRetentionDays
    @AppStorage(AppSettings.notificationsEnabledKey) private var notificationsEnabled = true
    @AppStorage(AppSettings.showDockIconWhenClosedKey) private var showDockIconWhenClosed = false

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemNote: String?
    @State private var isConfirmingStatisticsDeletion = false
    @State private var isConfirmingLogDeletion = false

    var body: some View {
        Form {
            Section {
                Picker("確認する間隔", selection: $checkInterval) {
                    ForEach(AppSettings.checkIntervalOptions, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }
            } header: {
                Text("監視")
            } footer: {
                Text("インターネットに接続できない間は、復旧をすぐに検知できるよう \(Int(AppSettings.offlineCheckInterval)) 秒ごとに確認します。ネットワークの切り替えやスリープ解除時にも自動で確認します。")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("ログイン時に起動", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginItemNote {
                    Text(loginItemNote).font(.caption).foregroundStyle(.secondary)
                }
                Toggle("ウインドウを閉じても Dock にアイコンを表示", isOn: $showDockIconWhenClosed)
                Toggle("接続が切れたとき・復旧したときに通知", isOn: $notificationsEnabled)
            } header: {
                Text("常駐")
            } footer: {
                Text("ウインドウを閉じてもメニューバーで接続状態の監視を続けます。終了するにはメニューバーのアイコンから「終了」を選択してください。")
                    .foregroundStyle(.secondary)
            }

            Section("データ") {
                Picker("記録の保存期間", selection: $retentionDays) {
                    ForEach(AppSettings.retentionOptions, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }
                LabeledContent("統計データ") {
                    Button("削除…", role: .destructive) { isConfirmingStatisticsDeletion = true }
                }
                LabeledContent("エラーログ") {
                    Button("削除…", role: .destructive) { isConfirmingLogDeletion = true }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: checkInterval) { monitor.reschedule() }
        .onChange(of: retentionDays) { monitor.applyRetentionPolicy() }
        .onChange(of: notificationsEnabled) { _, enabled in
            if enabled { monitor.requestNotificationAuthorization() }
        }
        .onAppear(perform: refreshLoginItemState)
        .confirmationDialog("すべての統計データを削除しますか？", isPresented: $isConfirmingStatisticsDeletion) {
            Button("削除", role: .destructive) {
                perform("統計データを削除できませんでした") { try monitor.deleteAllStatistics() }
            }
        } message: {
            Text("この操作は取り消せません。")
        }
        .confirmationDialog("すべてのエラーログを削除しますか？", isPresented: $isConfirmingLogDeletion) {
            Button("削除", role: .destructive) {
                perform("エラーログを削除できませんでした") { try monitor.deleteAllLogs() }
            }
        } message: {
            Text("この操作は取り消せません。")
        }
    }

    private func perform(_ failureMessage: String, _ action: () throws -> Void) {
        do { try action() } catch { Exporter.presentError(error, message: failureMessage) }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Exporter.presentError(error, message: enabled ? "ログイン項目に追加できませんでした" : "ログイン項目から削除できませんでした")
        }
        refreshLoginItemState()
    }

    private func refreshLoginItemState() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        loginItemNote = status == .requiresApproval
            ? "システム設定 > 一般 > ログイン項目と機能拡張 で、このアプリを許可してください。"
            : nil
    }
}
