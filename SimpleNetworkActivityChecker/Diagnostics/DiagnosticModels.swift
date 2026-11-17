import Foundation

/// 接続経路を Mac から外側に向かって順にたどる診断ステージ。
nonisolated enum DiagnosticStage: String, CaseIterable, Codable, Sendable, Identifiable {
    case link
    case address
    case gateway
    case internet
    case dns
    case web

    var id: String { rawValue }

    var title: String {
        switch self {
        case .link: "ネットワーク接続"
        case .address: "IPアドレス"
        case .gateway: "ルーター"
        case .internet: "インターネット"
        case .dns: "DNS"
        case .web: "Webアクセス"
        }
    }

    /// チェーン表示などで使う短い名前。
    var shortTitle: String {
        switch self {
        case .link: "接続"
        case .address: "IP"
        case .gateway: "ルーター"
        case .internet: "インターネット"
        case .dns: "DNS"
        case .web: "Web"
        }
    }

    var symbolName: String {
        switch self {
        case .link: "cable.connector"
        case .address: "number"
        case .gateway: "wifi.router"
        case .internet: "globe"
        case .dns: "text.magnifyingglass"
        case .web: "safari"
        }
    }

    /// このステージで何を確認しているかの説明。
    var explanation: String {
        switch self {
        case .link: "Wi‑Fi やイーサネットなど、Mac がネットワークに物理的に接続されているかを確認します。"
        case .address: "ルーター（DHCP）から有効な IP アドレスを取得できているかを確認します。"
        case .gateway: "家庭や職場のルーター（デフォルトゲートウェイ）まで通信が届くかを確認します。"
        case .internet: "ルーターの先、インターネット上のサーバーに IP アドレスで直接到達できるかを確認します。"
        case .dns: "ドメイン名（例: www.apple.com）を IP アドレスに変換できるかを確認します。"
        case .web: "実際に Web サイトへ HTTPS でアクセスできるかを確認します。"
        }
    }
}

nonisolated enum StageStatus: String, Codable, Sendable {
    case passed
    case warning
    case failed
    case skipped

    var label: String {
        switch self {
        case .passed: "正常"
        case .warning: "注意"
        case .failed: "失敗"
        case .skipped: "未実施"
        }
    }
}

/// 診断の解釈に使う補足情報。
nonisolated enum StageFlag: String, Codable, Sendable {
    case wifiOff
    case weakSignal
    case selfAssignedAddress
    case noRouter
    case noDNSServers
    case localNetworkDenied
    case captivePortal
    case packetLoss
    case slow
}

nonisolated struct StageResult: Codable, Sendable, Identifiable, Hashable {
    var stage: DiagnosticStage
    var status: StageStatus
    var summary: String
    var details: [String] = []
    var latencyMs: Double?
    var flags: [StageFlag] = []

    var id: DiagnosticStage { stage }

    static func skipped(_ stage: DiagnosticStage, reason: String = "前の段階で問題が見つかったため実施していません") -> StageResult {
        StageResult(stage: stage, status: .skipped, summary: reason)
    }
}

/// インターネット接続の総合的な状態。
nonisolated enum ConnectivityStatus: String, Codable, Sendable, CaseIterable {
    /// 問題なく利用可能
    case online
    /// 利用可能だが一部に問題がある
    case degraded
    /// インターネットを利用できない
    case offline

    var label: String {
        switch self {
        case .online: "オンライン"
        case .degraded: "一部に問題あり"
        case .offline: "オフライン"
        }
    }

    /// インターネットが利用可能かどうか（統計の稼働率計算に使用）。
    var isUp: Bool { self != .offline }
}

nonisolated enum InterfaceKind: String, Codable, Sendable {
    case wifi
    case ethernet
    case cellular
    case other

    var symbolName: String {
        switch self {
        case .wifi: "wifi"
        case .ethernet: "cable.connector.horizontal"
        case .cellular: "antenna.radiowaves.left.and.right"
        case .other: "network"
        }
    }
}

/// チェック時点のネットワーク構成。
nonisolated struct NetworkSnapshot: Codable, Sendable, Hashable {
    var interfaceName: String?
    var interfaceDisplayName: String?
    var interfaceKind: InterfaceKind = .other
    var ipv4Addresses: [String] = []
    var ipv6Addresses: [String] = []
    var subnetMasks: [String] = []
    var router: String?
    var dnsServers: [String] = []
    var wifiRSSI: Int?
    var wifiNoise: Int?
    var wifiTransmitRate: Double?
    var isExpensive = false
    var isConstrained = false

    var interfaceLabel: String {
        switch (interfaceDisplayName, interfaceName) {
        case let (display?, name?) where display != name: "\(display) (\(name))"
        case let (display?, _): display
        case let (nil, name?): name
        default: "なし"
        }
    }

    /// 自己割り当て（169.254.x.x）でない IPv4 アドレス。
    var usableIPv4Addresses: [String] {
        ipv4Addresses.filter { !$0.hasPrefix("169.254.") }
    }

    /// リンクローカル（fe80::）でない IPv6 アドレス。
    var globalIPv6Addresses: [String] {
        ipv6Addresses.filter { !$0.lowercased().hasPrefix("fe80") }
    }

    var wifiSignalDescription: String? {
        guard let rssi = wifiRSSI else { return nil }
        let quality = switch rssi {
        case (-55)...: "非常に良好"
        case (-67)...: "良好"
        case (-75)...: "やや弱い"
        default: "弱い"
        }
        return "\(rssi) dBm（\(quality)）"
    }
}

/// 診断結果に基づくユーザー向けの説明。
nonisolated struct Diagnosis: Codable, Sendable, Hashable {
    var headline: String
    var explanation: String
    var suggestions: [String]
}

nonisolated enum CheckTrigger: String, Codable, Sendable {
    case periodic
    case manual
    case networkChange
    case wake
    case launch

    var label: String {
        switch self {
        case .periodic: "定期"
        case .manual: "手動"
        case .networkChange: "ネットワーク変更"
        case .wake: "スリープ解除"
        case .launch: "起動時"
        }
    }
}

/// 1 回の接続診断の結果。
nonisolated struct DiagnosticReport: Codable, Sendable, Hashable {
    var date: Date
    var duration: TimeInterval
    var trigger: CheckTrigger
    var snapshot: NetworkSnapshot
    var stages: [StageResult]
    var status: ConnectivityStatus
    /// 最初に失敗した（インターネット利用不可の原因となった）ステージ。
    var failedStage: DiagnosticStage?
    var diagnosis: Diagnosis

    func result(for stage: DiagnosticStage) -> StageResult? {
        stages.first { $0.stage == stage }
    }

    /// ログ保存・コピー用の人間が読めるテキスト。
    var textReport: String {
        var lines: [String] = []
        lines.append("日時: \(date.formatted(date: .numeric, time: .standard))")
        lines.append("状態: \(status.label)")
        if let failedStage { lines.append("到達不能になった箇所: \(failedStage.title)") }
        lines.append("診断: \(diagnosis.headline)")
        lines.append("  \(diagnosis.explanation)")
        if !diagnosis.suggestions.isEmpty {
            lines.append("対処方法:")
            lines.append(contentsOf: diagnosis.suggestions.map { "  ・\($0)" })
        }
        lines.append("")
        lines.append("[接続情報]")
        lines.append("インターフェース: \(snapshot.interfaceLabel)")
        if let signal = snapshot.wifiSignalDescription { lines.append("Wi‑Fi 信号強度: \(signal)") }
        lines.append("IPv4: \(snapshot.ipv4Addresses.isEmpty ? "なし" : snapshot.ipv4Addresses.joined(separator: ", "))")
        lines.append("IPv6: \(snapshot.ipv6Addresses.isEmpty ? "なし" : snapshot.ipv6Addresses.joined(separator: ", "))")
        lines.append("ルーター: \(snapshot.router ?? "なし")")
        lines.append("DNS サーバー: \(snapshot.dnsServers.isEmpty ? "なし" : snapshot.dnsServers.joined(separator: ", "))")
        lines.append("")
        lines.append("[各段階の結果]")
        for stage in stages {
            var line = "\(stage.status == .passed ? "✓" : stage.status == .warning ? "!" : stage.status == .failed ? "✗" : "-") \(stage.stage.title): \(stage.summary)"
            if let latency = stage.latencyMs { line += String(format: " (%.1f ms)", latency) }
            lines.append(line)
            lines.append(contentsOf: stage.details.map { "    \($0)" })
        }
        lines.append("")
        lines.append("チェック種別: \(trigger.label) / 所要時間: \(String(format: "%.1f", duration)) 秒")
        return lines.joined(separator: "\n")
    }
}
