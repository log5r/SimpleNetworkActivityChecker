import SwiftUI

/// 「この Mac」から Web までの経路を左から右に並べ、どこで途切れているかを示す。
struct ReachabilityChainView: View {
    var report: DiagnosticReport?
    var compact = false

    private var iconSize: CGFloat { compact ? 13 : 20 }
    private var circleSize: CGFloat { compact ? 28 : 46 }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack(alignment: .top, spacing: 0) {
                node(symbol: "laptopcomputer", title: compact ? "Mac" : "この Mac", status: report == nil ? nil : .passed,
                     caption: nil, isBreakPoint: false)
                ForEach(DiagnosticStage.allCases) { stage in
                    let result = report?.result(for: stage)
                    connector(status: result?.status)
                    node(symbol: symbol(for: stage),
                         title: compact ? stage.shortTitle : stage.title,
                         status: result?.status,
                         caption: result?.latencyMs.map { String(format: "%.0f ms", $0) },
                         isBreakPoint: report?.failedStage == stage)
                }
            }
            if !compact, let failed = report?.failedStage {
                Label {
                    Text("「\(failed.title)」の段階で途切れています。\(Text(reachedText(before: failed)).foregroundStyle(.secondary))")
                } icon: {
                    Image(systemName: "bolt.horizontal.fill").foregroundStyle(.red)
                }
                .font(.callout)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("接続経路")
    }

    private func reachedText(before stage: DiagnosticStage) -> String {
        let reached = DiagnosticStage.allCases.prefix { $0 != stage }
            .filter { report?.result(for: $0).map { [.passed, .warning].contains($0.status) } ?? false }
        guard let last = reached.last else { return "" }
        return "「\(last.title)」までは正常です。"
    }

    private func symbol(for stage: DiagnosticStage) -> String {
        if stage == .link, let kind = report?.snapshot.interfaceKind, report?.snapshot.interfaceName != nil {
            return kind.symbolName
        }
        return stage.symbolName
    }

    private func node(symbol: String, title: String, status: StageStatus?, caption: String?, isBreakPoint: Bool) -> some View {
        let color = status?.color ?? Color.secondary
        return VStack(spacing: compact ? 3 : 6) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(color.opacity(status == nil || status == .skipped ? 0.08 : 0.18))
                    .overlay(Circle().strokeBorder(color.opacity(status == .skipped ? 0.3 : 0.9), lineWidth: isBreakPoint ? 2.5 : 1.5))
                    .frame(width: circleSize, height: circleSize)
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: iconSize, weight: .medium))
                            .foregroundStyle(status == .skipped || status == nil ? Color.secondary : color)
                    }
                if let status, status != .passed, status != .skipped {
                    Image(systemName: status.symbolName)
                        .font(.system(size: compact ? 10 : 15))
                        .foregroundStyle(.white, status.color)
                        .background(Circle().fill(.background).padding(1))
                        .offset(x: 3, y: 3)
                }
            }
            Text(title)
                .font(compact ? .system(size: 9) : .caption)
                .fontWeight(isBreakPoint ? .bold : .regular)
                .foregroundStyle(status == .skipped ? .secondary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !compact {
                Text(caption ?? " ")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: compact ? 38 : 76)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(status?.label ?? "未確認")\(isBreakPoint ? "、ここで途切れています" : "")")
    }

    private func connector(status: StageStatus?) -> some View {
        let color = status?.color ?? Color.secondary
        return Group {
            if status == .failed || status == .skipped || status == nil {
                Line()
                    .stroke(color.opacity(status == .failed ? 0.9 : 0.35), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            } else {
                Line()
                    .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 2.5))
            }
        }
        .frame(minWidth: compact ? 2 : 6, maxWidth: .infinity)
        .frame(height: circleSize)
        .accessibilityHidden(true)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}

#Preview {
    ReachabilityChainView(report: nil)
        .padding()
        .frame(width: 720)
}
