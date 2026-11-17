import AppKit
import SwiftUI

/// メニューバーのアイコン。
struct MenuBarLabel: View {
    var monitor: NetworkMonitor

    var body: some View {
        let status = monitor.status
        Image(systemName: status?.menuBarSymbolName ?? "network")
            .accessibilityLabel("ネットワーク状態: \(status?.label ?? "確認中")")
    }
}

/// メニューバーのアイコンをクリックしたときに表示されるパネル。
struct MenuBarContentView: View {
    @Environment(NetworkMonitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let report = monitor.latestReport
        VStack(alignment: .leading, spacing: 12) {
            StatusHeadline(report: report, isChecking: monitor.isChecking, outageStart: monitor.outageStart, compact: true)

            ReachabilityChainView(report: report, compact: true)
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            if let report {
                if report.status != .online {
                    Text(report.diagnosis.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    infoRow("接続", report.snapshot.interfaceLabel)
                    if let signal = report.snapshot.wifiSignalDescription { infoRow("信号", signal) }
                    infoRow("IP", (report.snapshot.usableIPv4Addresses.first ?? report.snapshot.ipv4Addresses.first) ?? "なし")
                    infoRow("ルーター", report.snapshot.router ?? "なし")
                    if let web = report.result(for: .web)?.latencyMs {
                        infoRow("応答", String(format: "%.0f ms", web))
                    }
                }
                .font(.caption)
            }

            Divider()

            // 標準のボタン。キーボードショートカットはパネル表示中に有効になる
            HStack(spacing: 8) {
                Button("今すぐチェック") { monitor.checkNow() }
                    .keyboardShortcut("r")
                    .disabled(monitor.isChecking)
                Button("ウインドウを開く") { showMainWindow() }
                Spacer(minLength: 0)
                Button("設定…", systemImage: "gearshape") {
                    NSApp.activate()
                    openSettings()
                }
                .keyboardShortcut(",")
                .help("設定…")
                Button("終了", systemImage: "power") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                    .help("終了")
            }
            .labelStyle(.iconOnly)
        }
        .padding(14)
        .frame(width: 340)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: MainWindow.id)
        NSApp.activate()
    }
}
