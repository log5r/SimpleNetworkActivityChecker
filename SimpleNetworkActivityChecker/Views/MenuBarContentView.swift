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

            VStack(spacing: 0) {
                MenuRow(title: "今すぐチェック", systemImage: "arrow.clockwise", shortcut: "⌘R") {
                    monitor.checkNow()
                }
                .disabled(monitor.isChecking)
                MenuRow(title: "ウインドウを開く", systemImage: "macwindow") {
                    showMainWindow()
                }
                MenuRow(title: "設定…", systemImage: "gearshape", shortcut: "⌘,") {
                    NSApp.activate()
                    openSettings()
                }
                Divider().padding(.vertical, 4)
                MenuRow(title: "終了", systemImage: "power", shortcut: "⌘Q") {
                    NSApp.terminate(nil)
                }
            }
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

/// メニュー項目風のボタン（ホバーで強調表示）。
private struct MenuRow: View {
    var title: String
    var systemImage: String
    var shortcut: String?
    var action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(isHovering && isEnabled ? Color.white.opacity(0.8) : .secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(isHovering && isEnabled ? Color.white : .primary)
            .background(isHovering && isEnabled ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
