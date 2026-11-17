import AppKit
import SwiftUI

/// 現在のインターネット接続状態と診断結果。
struct StatusView: View {
    @Environment(NetworkMonitor.self) private var monitor

    var body: some View {
        let report = monitor.latestReport
        Form {
            Section {
                StatusHeadline(report: report, isChecking: monitor.isChecking, outageStart: monitor.outageStart)
                    .padding(.vertical, 4)
                ReachabilityChainView(report: report)
                    .padding(.vertical, 6)
            }

            if let report, !report.diagnosis.suggestions.isEmpty {
                Section("対処方法") {
                    ForEach(Array(report.diagnosis.suggestions.enumerated()), id: \.offset) { index, suggestion in
                        Label {
                            Text(suggestion).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "\(index + 1).circle.fill").foregroundStyle(.tint)
                        }
                    }
                }
            }

            if let report {
                Section {
                    ForEach(report.stages) { stage in
                        StageRow(result: stage, isBreakPoint: report.failedStage == stage.stage)
                    }
                } header: {
                    Text("各段階の結果")
                } footer: {
                    Text("Mac から近い順に確認しています。各項目をクリックすると詳細を表示します。")
                        .foregroundStyle(.secondary)
                }

                Section("接続情報") {
                    LabeledContent("インターフェース", value: report.snapshot.interfaceLabel)
                    if let signal = report.snapshot.wifiSignalDescription {
                        LabeledContent("Wi‑Fi 信号強度", value: signal)
                    }
                    if let rate = report.snapshot.wifiTransmitRate {
                        LabeledContent("転送レート", value: "\(Int(rate)) Mbps")
                    }
                    LabeledContent("IPv4 アドレス", value: report.snapshot.ipv4Addresses.joined(separator: ", ").ifEmpty("なし"))
                    if !report.snapshot.globalIPv6Addresses.isEmpty {
                        LabeledContent("IPv6 アドレス", value: report.snapshot.globalIPv6Addresses.joined(separator: "\n"))
                    }
                    LabeledContent("ルーター", value: report.snapshot.router ?? "なし")
                    LabeledContent("DNS サーバー", value: report.snapshot.dnsServers.joined(separator: "\n").ifEmpty("なし"))
                    if report.snapshot.isExpensive || report.snapshot.isConstrained {
                        LabeledContent("回線の種類") {
                            Text([report.snapshot.isExpensive ? "従量課金（テザリングなど）" : nil,
                                  report.snapshot.isConstrained ? "省データモード" : nil]
                                .compactMap { $0 }.joined(separator: "、"))
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("状態")
        .toolbar {
            ToolbarItemGroup {
                if let report {
                    Button("診断結果をコピー", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.textReport, forType: .string)
                    }
                    .help("診断結果をテキストとしてクリップボードにコピーします")
                }
                Button("今すぐチェック", systemImage: "arrow.clockwise") {
                    monitor.checkNow()
                }
                .disabled(monitor.isChecking)
                .help("今すぐ接続状態を確認します (⌘R)")
            }
        }
    }
}

private struct StageRow: View {
    var result: StageResult
    var isBreakPoint: Bool
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.stage.explanation)
                    .foregroundStyle(.secondary)
                ForEach(result.details, id: \.self) { detail in
                    Text(detail).font(.callout.monospacedDigit())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(.leading, 28)
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: result.status.symbolName)
                    .foregroundStyle(result.status.color)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(result.stage.title).fontWeight(.medium)
                        if isBreakPoint {
                            Text("ここで途切れています")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.red, in: Capsule())
                        }
                    }
                    Text(result.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let latency = result.latencyMs {
                    Text(String(format: "%.1f ms", latency))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { isExpanded.toggle() } }
            .accessibilityElement(children: .combine)
        }
    }
}

extension String {
    func ifEmpty(_ replacement: String) -> String { isEmpty ? replacement : self }
}
