import SwiftUI

extension StageStatus {
    var color: Color {
        switch self {
        case .passed: .green
        case .warning: .orange
        case .failed: .red
        case .skipped: .secondary
        }
    }

    var symbolName: String {
        switch self {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        case .skipped: "minus.circle"
        }
    }
}

extension ConnectivityStatus {
    var color: Color {
        switch self {
        case .online: .green
        case .degraded: .orange
        case .offline: .red
        }
    }

    var symbolName: String {
        switch self {
        case .online: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .offline: "xmark.octagon.fill"
        }
    }

    /// メニューバー用（テンプレート画像として単色で表示される）
    var menuBarSymbolName: String {
        switch self {
        case .online: "network"
        case .degraded: "exclamationmark.triangle"
        case .offline: "network.slash"
        }
    }
}

extension LogEventKind {
    var color: Color {
        switch self {
        case .outage: .red
        case .causeChanged: .orange
        case .restored: .green
        }
    }
}

/// 状態の見出し（アイコン＋タイトル＋説明）。
struct StatusHeadline: View {
    var report: DiagnosticReport?
    var isChecking: Bool
    var outageStart: Date?
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 10 : 14) {
            Group {
                if let report {
                    Image(systemName: report.status.symbolName)
                        .foregroundStyle(report.status.color)
                        .contentTransition(.symbolEffect(.replace))
                } else {
                    Image(systemName: "network")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: compact ? 28 : 40))
            .frame(width: compact ? 32 : 48)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(report?.diagnosis.headline ?? "接続状態を確認しています…")
                    .font(compact ? .headline : .title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                if let report, !compact {
                    Text(report.diagnosis.explanation)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    if isChecking {
                        ProgressView().controlSize(.small)
                        Text("確認中…")
                    } else if let report {
                        Text("最終確認: \(report.date.formatted(date: .omitted, time: .standard))")
                    }
                    if let outageStart {
                        Text("・")
                        Text("停止 \(Text(outageStart, style: .relative))")
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
