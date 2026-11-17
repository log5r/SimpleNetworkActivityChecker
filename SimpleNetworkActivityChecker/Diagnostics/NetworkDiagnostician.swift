import Foundation

/// Mac → ルーター → インターネット → DNS → Web の順に到達性を調べ、問題の箇所を特定する。
nonisolated enum NetworkDiagnostician {
    static let internetTargets: [(host: String, name: String)] = [
        ("1.1.1.1", "Cloudflare"),
        ("8.8.8.8", "Google"),
    ]

    private static let weakSignalThreshold = -75
    private static let slowInternetMs = 300.0
    private static let slowDNSMs = 1_000.0
    private static let slowWebMs = 3_000.0

    @concurrent
    static func run(trigger: CheckTrigger) async -> DiagnosticReport {
        let started = Date()
        let clock = ContinuousClock.now
        let state = NetworkInfoProvider.currentState()
        let snapshot = state.snapshot

        var stages: [StageResult] = []

        // 1. リンク
        let link = checkLink(state)
        stages.append(link)

        // 2. IP アドレス
        let address = link.status == .failed ? .skipped(.address) : checkAddress(snapshot)
        stages.append(address)

        if address.status == .failed || address.status == .skipped {
            stages += [.skipped(.gateway), .skipped(.internet), .skipped(.dns), .skipped(.web)]
        } else {
            // 3〜6 は互いに独立しているので並行して確認する
            async let gateway = checkGateway(snapshot.router)
            async let internet = checkInternet()
            async let dns = checkDNS(snapshot.dnsServers)
            async let web = checkWeb()
            stages += await [gateway, internet, dns, web]
        }

        let (status, failedStage, adjusted) = evaluate(stages)
        let diagnosis = makeDiagnosis(status: status, failedStage: failedStage, stages: adjusted, snapshot: snapshot)

        return DiagnosticReport(
            date: started,
            duration: clock.duration(to: .now).milliseconds / 1000,
            trigger: trigger,
            snapshot: snapshot,
            stages: adjusted,
            status: status,
            failedStage: failedStage,
            diagnosis: diagnosis
        )
    }

    // MARK: - Stages

    private static func checkLink(_ state: NetworkInfoProvider.LinkState) -> StageResult {
        let snapshot = state.snapshot
        guard state.hasActiveLink else {
            var result = StageResult(stage: .link, status: .failed, summary: "有効なネットワーク接続がありません")
            if state.wifiPowerOn == false {
                result.summary = "Wi‑Fi がオフで、有線接続もありません"
                result.flags.append(.wifiOff)
            } else if state.wifiPowerOn == true {
                result.details.append("Wi‑Fi はオンですが、どのネットワークにも接続されていません")
            }
            for hw in state.hardwareInterfaces {
                result.details.append("\(hw.displayName) (\(hw.bsdName)): \(hw.linkActive ? "接続" : "未接続")")
            }
            return result
        }

        var result = StageResult(stage: .link, status: .passed, summary: "\(snapshot.interfaceLabel) で接続しています")
        if let signal = snapshot.wifiSignalDescription {
            result.details.append("信号強度: \(signal)")
        }
        if let noise = snapshot.wifiNoise { result.details.append("ノイズ: \(noise) dBm") }
        if let rate = snapshot.wifiTransmitRate { result.details.append("転送レート: \(Int(rate)) Mbps") }
        if let rssi = snapshot.wifiRSSI, rssi < weakSignalThreshold {
            result.status = .warning
            result.summary = "\(snapshot.interfaceLabel) で接続していますが、電波が弱い状態です"
            result.flags.append(.weakSignal)
        }
        return result
    }

    private static func checkAddress(_ snapshot: NetworkSnapshot) -> StageResult {
        let usable = snapshot.usableIPv4Addresses + snapshot.globalIPv6Addresses
        if !usable.isEmpty {
            var result = StageResult(stage: .address, status: .passed, summary: usable.first!)
            if !snapshot.usableIPv4Addresses.isEmpty {
                result.details.append("IPv4: \(snapshot.usableIPv4Addresses.joined(separator: ", "))")
            }
            if !snapshot.subnetMasks.isEmpty {
                result.details.append("サブネットマスク: \(snapshot.subnetMasks.joined(separator: ", "))")
            }
            if !snapshot.globalIPv6Addresses.isEmpty {
                result.details.append("IPv6: \(snapshot.globalIPv6Addresses.joined(separator: ", "))")
            }
            return result
        }
        if snapshot.ipv4Addresses.contains(where: { $0.hasPrefix("169.254.") }) {
            return StageResult(
                stage: .address, status: .failed,
                summary: "自己割り当て IP アドレス（\(snapshot.ipv4Addresses.joined(separator: ", "))）しかありません",
                details: ["DHCP サーバー（通常はルーター）から IP アドレスを取得できていません"],
                flags: [.selfAssignedAddress]
            )
        }
        return StageResult(stage: .address, status: .failed, summary: "IP アドレスが割り当てられていません",
                           details: ["DHCP サーバー（通常はルーター）から応答がありません"])
    }

    private static func checkGateway(_ router: String?) async -> StageResult {
        guard let router else {
            return StageResult(stage: .gateway, status: .failed, summary: "ルーター（デフォルトゲートウェイ）が設定されていません",
                               flags: [.noRouter])
        }

        let ping = await ICMPPinger.ping(router, count: 3, timeout: 1)
        if ping.received > 0, let average = ping.averageMs {
            var result = StageResult(
                stage: .gateway, status: .passed,
                summary: "\(router) から応答があります",
                details: [String(format: "ping: %d/%d 応答、平均 %.1f ms", ping.received, ping.sent, average)],
                latencyMs: average
            )
            if ping.received < ping.sent {
                result.status = .warning
                result.summary = String(format: "\(router) から応答がありますが、パケットロスがあります（%.0f%%）", ping.lossPercent)
                result.flags.append(.packetLoss)
            }
            return result
        }

        // ping に応答しないルーターもあるので TCP でも確認する（拒否応答でも到達はしている）
        var details: [String] = ["ping: 応答なし\(ping.error.map { "（\($0)）" } ?? "")"]
        async let http = TCPProbe.connect(host: router, port: 80, timeout: 2)
        async let https = TCPProbe.connect(host: router, port: 443, timeout: 2)
        async let dns = TCPProbe.connect(host: router, port: 53, timeout: 2)
        let tcpResults = await [(80, http), (443, https), (53, dns)]

        if let (port, outcome) = tcpResults.first(where: { $0.1.isReachable }) {
            details.append("TCP \(port): \(outcome.latencyMs.map { String(format: "%.1f ms で応答", $0) } ?? "応答")")
            return StageResult(stage: .gateway, status: .passed, summary: "\(router) に到達できます",
                               details: details, latencyMs: outcome.latencyMs)
        }
        if tcpResults.contains(where: { if case .localNetworkDenied = $0.1 { true } else { false } }) {
            return StageResult(
                stage: .gateway, status: .skipped,
                summary: "ローカルネットワークへのアクセスが許可されていないため確認できません",
                details: ["システム設定 > プライバシーとセキュリティ > ローカルネットワーク で許可すると確認できます"],
                flags: [.localNetworkDenied]
            )
        }
        for (port, outcome) in tcpResults {
            if case .failed(let message) = outcome { details.append("TCP \(port): \(message)") }
        }
        return StageResult(stage: .gateway, status: .failed, summary: "\(router) から応答がありません", details: details)
    }

    private static func checkInternet() async -> StageResult {
        let outcomes = await withTaskGroup(of: (Int, ProbeOutcome).self) { group in
            for (index, target) in internetTargets.enumerated() {
                group.addTask { (index, await TCPProbe.connect(host: target.host, port: 443, timeout: 4)) }
            }
            var results: [(Int, ProbeOutcome)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var details: [String] = []
        for (target, outcome) in zip(internetTargets, outcomes) {
            let text = switch outcome {
            case .connected(let ms): String(format: "%.1f ms で接続", ms)
            case .refused(let ms): String(format: "%.1f ms で応答（拒否）", ms)
            case .localNetworkDenied: "ローカルネットワークの許可がありません"
            case .failed(let message): message
            }
            details.append("\(target.name) (\(target.host)): \(text)")
        }

        let latencies = outcomes.compactMap(\.latencyMs)
        guard let best = latencies.min() else {
            let hosts = internetTargets.map(\.host).joined(separator: "、")
            return StageResult(stage: .internet, status: .failed,
                               summary: "インターネット上のサーバー（\(hosts)）に到達できません", details: details)
        }
        if best > slowInternetMs {
            return StageResult(stage: .internet, status: .warning,
                               summary: String(format: "到達できますが応答が遅い状態です（%.0f ms）", best),
                               details: details, latencyMs: best, flags: [.slow])
        }
        return StageResult(stage: .internet, status: .passed, summary: "インターネット上のサーバーに到達できます",
                           details: details, latencyMs: best)
    }

    private static func checkDNS(_ servers: [String]) async -> StageResult {
        guard !servers.isEmpty else {
            let system = await DNSProbe.systemResolve("www.apple.com")
            if system.isReachable {
                return StageResult(stage: .dns, status: .passed, summary: "システムのリゾルバで名前解決できます",
                                   details: ["DNS サーバーの設定が見つかりませんでした（暗号化 DNS などを利用している可能性があります）"],
                                   latencyMs: system.latencyMs)
            }
            return StageResult(stage: .dns, status: .failed, summary: "DNS サーバーが設定されていません", flags: [.noDNSServers])
        }

        let targets = Array(servers.prefix(3))
        let outcomes = await withTaskGroup(of: (Int, DNSOutcome).self) { group in
            for (index, server) in targets.enumerated() {
                group.addTask { (index, await DNSProbe.query(server: server)) }
            }
            var results: [(Int, DNSOutcome)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var details: [String] = []
        var best: (server: String, latency: Double)?
        var serverErrors: [String] = []
        var denied = false
        for (server, outcome) in zip(targets, outcomes) {
            switch outcome {
            case .answered(let ms, let count):
                details.append(String(format: "%@: %.1f ms で応答（回答 %d 件）", server, ms, count))
                if best == nil || ms < best!.latency { best = (server, ms) }
            case .serverError(let code, let ms):
                let description = DNSOutcome.rcodeDescription(code)
                details.append(String(format: "%@: エラー応答 %@（%.1f ms）", server, description, ms))
                serverErrors.append(description)
            case .localNetworkDenied:
                details.append("\(server): ローカルネットワークの許可がないため直接確認できません")
                denied = true
            case .failed(let message):
                details.append("\(server): \(message)")
            }
        }

        if let best {
            if best.latency > slowDNSMs {
                return StageResult(stage: .dns, status: .warning,
                                   summary: String(format: "%@ が応答しましたが遅い状態です（%.0f ms）", best.server, best.latency),
                                   details: details, latencyMs: best.latency, flags: [.slow])
            }
            return StageResult(stage: .dns, status: .passed, summary: "\(best.server) で名前解決できます",
                               details: details, latencyMs: best.latency)
        }
        if !serverErrors.isEmpty {
            return StageResult(stage: .dns, status: .failed,
                               summary: "DNS サーバーがエラーを返しました（\(serverErrors[0])）", details: details)
        }

        // 直接問い合わせできなかった場合はシステムのリゾルバでも確認する
        let system = await DNSProbe.systemResolve("www.apple.com")
        if system.isReachable {
            details.append("システムのリゾルバ: 名前解決できました\(denied ? "" : "（キャッシュの可能性があります）")")
            return StageResult(stage: .dns, status: denied ? .passed : .warning,
                               summary: denied ? "システムのリゾルバで名前解決できます"
                                               : "DNS サーバーから直接の応答はありませんが、名前解決はできています",
                               details: details, latencyMs: system.latencyMs,
                               flags: denied ? [.localNetworkDenied] : [])
        }
        if case .failed(let message) = system { details.append("システムのリゾルバ: \(message)") }
        return StageResult(stage: .dns, status: .failed,
                           summary: "DNS サーバー（\(targets.joined(separator: "、"))）から応答がありません", details: details)
    }

    private static func checkWeb() async -> StageResult {
        let outcomes = await withTaskGroup(of: (Int, HTTPOutcome).self) { group in
            for (index, target) in HTTPProbe.targets.enumerated() {
                group.addTask { (index, await HTTPProbe.fetch(target)) }
            }
            var results: [(Int, HTTPOutcome)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var details: [String] = []
        var best: Double?
        for (target, outcome) in zip(HTTPProbe.targets, outcomes) {
            let host = target.url.host() ?? target.url.absoluteString
            switch outcome {
            case .success(let ms):
                details.append(String(format: "%@: %.0f ms で応答", host, ms))
                best = min(best ?? .infinity, ms)
            case .unexpectedResponse(let code, let ms):
                details.append(String(format: "%@: 想定外の応答（HTTP %d、%.0f ms）", host, code, ms))
            case .failed(_, let message):
                details.append("\(host): \(message)")
            }
        }

        if let best {
            if best > slowWebMs {
                return StageResult(stage: .web, status: .warning,
                                   summary: String(format: "Web にアクセスできますが応答が遅い状態です（%.1f 秒）", best / 1000),
                                   details: details, latencyMs: best, flags: [.slow])
            }
            return StageResult(stage: .web, status: .passed, summary: "Web サイトにアクセスできます",
                               details: details, latencyMs: best)
        }

        // HTTPS が失敗した場合、ログイン画面（キャプティブポータル）による書き換えが起きていないか確認する
        let captive = await HTTPProbe.captivePortalCheck()
        switch captive {
        case .captive(let redirect):
            details.append("captive.apple.com への HTTP アクセスが別のページに置き換えられました")
            if let redirect { details.append("転送先: \(redirect)") }
            return StageResult(stage: .web, status: .failed,
                               summary: "ネットワークへのログイン（認証）が必要です", details: details, flags: [.captivePortal])
        case .notCaptive:
            details.append("captive.apple.com: HTTP では正常に応答")
        case .failed(let message):
            details.append("captive.apple.com: \(message)")
        }
        return StageResult(stage: .web, status: .failed, summary: "Web サイトにアクセスできません", details: details)
    }

    // MARK: - Evaluation

    /// 各ステージの結果から総合状態と「最初に到達不能になった箇所」を決める。
    /// 後段が成功している場合、前段の失敗は単にプローブに応答しないだけなので原因とはみなさない。
    static func evaluate(_ input: [StageResult]) -> (ConnectivityStatus, DiagnosticStage?, [StageResult]) {
        var stages = input
        func index(_ stage: DiagnosticStage) -> Int { stages.firstIndex { $0.stage == stage }! }
        func status(_ stage: DiagnosticStage) -> StageStatus { stages[index(stage)].status }
        func reachable(_ stage: DiagnosticStage) -> Bool { [.passed, .warning].contains(status(stage)) }

        if status(.link) == .failed { return (.offline, .link, stages) }
        if status(.address) == .failed { return (.offline, .address, stages) }

        let webOK = reachable(.web)

        // インターネットに到達できているならルーターは機能している
        if status(.gateway) == .failed, reachable(.internet) || webOK {
            let i = index(.gateway)
            stages[i].status = .passed
            stages[i].details.insert(stages[i].summary, at: 0)
            stages[i].summary = "ルーターは確認用の通信に応答しませんが、その先には到達できています"
        }
        // プロキシ経由などで Web にアクセスできるなら直接接続の失敗は問題にしない
        if status(.internet) == .failed, webOK {
            let i = index(.internet)
            stages[i].status = .passed
            stages[i].details.insert(stages[i].summary, at: 0)
            stages[i].summary = "直接接続はできませんが、Web へは（プロキシ経由などで）アクセスできます"
        }
        if status(.dns) == .failed, webOK {
            let i = index(.dns)
            stages[i].status = .warning
        }

        if webOK {
            let hasWarning = stages.contains { $0.status == .warning }
            return (hasWarning ? .degraded : .online, nil, stages)
        }

        // ログイン画面（キャプティブポータル）は認証前の通信をまとめて遮断するため、ルーターや
        // インターネットへの確認も失敗する。ログイン画面に置き換えられた確かな根拠（別ホストへの転送や
        // 書き換えられた本文。HTTPProbe.classifyCaptivePortalResponse を参照）がある場合だけ、そちらを原因として優先する。
        // 通信の失敗やサーバーエラーではこのフラグは付かないので、ルーター・インターネット・DNS の失敗がそのまま原因になる。
        let web = stages[index(.web)]
        let captivePortal = web.status == .failed && web.flags.contains(.captivePortal)

        let failed: DiagnosticStage = if captivePortal {
            .web
        } else if status(.gateway) == .failed, !reachable(.internet) {
            .gateway
        } else if status(.internet) == .failed {
            .internet
        } else if status(.dns) == .failed {
            .dns
        } else {
            .web
        }
        return (.offline, failed, stages)
    }

    // MARK: - Diagnosis

    static func makeDiagnosis(status: ConnectivityStatus, failedStage: DiagnosticStage?,
                                      stages: [StageResult], snapshot: NetworkSnapshot) -> Diagnosis {
        let flags = Set(stages.flatMap(\.flags))
        let interface = snapshot.interfaceLabel
        let router = snapshot.router ?? "ルーター"
        let permissionHint = "システム設定 > プライバシーとセキュリティ > ローカルネットワーク で本アプリを許可すると、ルーターまでの到達性も確認できます"

        switch failedStage {
        case .link:
            if flags.contains(.wifiOff) {
                return Diagnosis(
                    headline: "Wi‑Fi がオフになっています",
                    explanation: "Mac はどのネットワークにも接続されていません。Wi‑Fi がオフで、有線 LAN の接続も見つかりません。",
                    suggestions: [
                        "コントロールセンターまたはシステム設定の「Wi‑Fi」で Wi‑Fi をオンにしてください",
                        "有線 LAN を使う場合は、ケーブルとアダプタが接続されているか確認してください",
                    ])
            }
            return Diagnosis(
                headline: "ネットワークに接続されていません",
                explanation: "Mac は Wi‑Fi ネットワークに接続されていないか、LAN ケーブルが外れています。通信は Mac の外に出ていません。",
                suggestions: [
                    "コントロールセンターの Wi‑Fi メニューから接続するネットワークを選択してください",
                    "LAN ケーブルやアダプタがしっかり接続されているか確認してください",
                    "システム設定 > ネットワーク で、使用するサービスが有効になっているか確認してください",
                ])

        case .address:
            let explanation = flags.contains(.selfAssignedAddress)
                ? "Mac は \(interface) に接続されていますが、ルーター（DHCP サーバー）から IP アドレスが割り当てられず、自己割り当てアドレス（169.254.x.x）になっています。この状態ではルーターより先と通信できません。"
                : "Mac は \(interface) に接続されていますが、IP アドレスが割り当てられていません。ルーター（DHCP サーバー）から応答がない可能性があります。"
            return Diagnosis(
                headline: "IP アドレスを取得できていません",
                explanation: explanation,
                suggestions: [
                    "Wi‑Fi をいったんオフにしてから再度オンにしてください",
                    "システム設定 > ネットワーク > \(snapshot.interfaceDisplayName ?? "使用中のサービス") > 詳細 > TCP/IP で「DHCP リースを更新」を実行してください",
                    "ルーターを再起動してください",
                    "ルーターの接続台数の上限や MAC アドレスフィルタリングの設定を確認してください",
                ])

        case .gateway:
            if flags.contains(.noRouter) {
                return Diagnosis(
                    headline: "ルーターの情報がありません",
                    explanation: "IP アドレスはありますが、デフォルトゲートウェイ（ルーター）が設定されていないため、ネットワークの外に出られません。",
                    suggestions: [
                        "システム設定 > ネットワーク > 詳細 > TCP/IP で「DHCP リースを更新」を実行してください",
                        "IP アドレスを手動で設定している場合は、ルーターのアドレスが正しく入力されているか確認してください",
                    ])
            }
            var suggestions = [
                "ルーターの電源が入っているか、ランプに異常がないか確認してください",
                "ルーターを再起動してください",
                "スマートフォンなど他の機器が同じネットワークで通信できるか確認してください",
            ]
            if flags.contains(.weakSignal) {
                suggestions.insert("Wi‑Fi の電波が弱くなっています。ルーターに近づくか、障害物を減らしてください", at: 0)
            }
            return Diagnosis(
                headline: "ルーターに到達できません",
                explanation: "Mac は \(interface) に接続されていますが、ルーター（\(router)）から応答がありません。Mac とルーターの間で通信が途切れています。",
                suggestions: suggestions)

        case .internet:
            var explanation = "Mac からルーター（\(router)）までは通信できていますが、その先のインターネットに出られません。光回線終端装置（ONU）・モデム、プロバイダの回線、またはルーターのインターネット側（WAN）の接続に問題がある可能性があります。"
            var suggestions = [
                "ONU／モデムとルーターを再起動してください（ONU／モデム → ルーターの順に電源を入れます）",
                "ONU／モデムのランプに異常（消灯・赤点灯など）がないか確認してください",
                "契約しているプロバイダの障害・メンテナンス情報を確認してください",
                "ルーターの管理画面で、インターネット（WAN）側の接続状態を確認してください",
            ]
            if flags.contains(.localNetworkDenied) {
                explanation = "インターネット上のサーバーに到達できません。（ローカルネットワークへのアクセスが許可されていないため、ルーターまで到達できているかは確認できませんでした）"
                suggestions.append(permissionHint)
            }
            return Diagnosis(headline: "ルーターより先（インターネット回線）で途切れています", explanation: explanation, suggestions: suggestions)

        case .dns:
            let servers = snapshot.dnsServers.isEmpty ? "DNS サーバー" : snapshot.dnsServers.joined(separator: "、")
            return Diagnosis(
                headline: "DNS（名前解決）に失敗しています",
                explanation: "インターネットには IP アドレスで到達できていますが、DNS サーバー（\(servers)）が応答しないため、Web サイトの名前を IP アドレスに変換できません。そのためブラウザなどでページを開けません。",
                suggestions: [
                    "ルーターを再起動してください（ルーターが DNS を中継している場合に有効です）",
                    "システム設定 > ネットワーク > 詳細 > DNS で、公開 DNS（1.1.1.1 や 8.8.8.8 など）を追加すると改善する場合があります",
                    "VPN やセキュリティソフトを使用している場合は、一時的に無効にして確認してください",
                ])

        case .web:
            if flags.contains(.captivePortal) {
                return Diagnosis(
                    headline: "ネットワークへのログインが必要です",
                    explanation: "ホテル・カフェ・空港などの公衆 Wi‑Fi で、ログイン（認証）画面を通過するまでインターネットに接続できない状態です。",
                    suggestions: [
                        "Safari などのブラウザで任意の Web ページを開き、表示されるログイン画面で認証してください",
                        "ログイン画面が表示されない場合は http://captive.apple.com を開いてください",
                    ])
            }
            return Diagnosis(
                headline: "Web サイトに接続できません",
                explanation: "インターネットと DNS には到達できていますが、HTTPS による Web アクセスに失敗しました。プロキシ、ファイアウォール、セキュリティソフトなどによって通信が遮断されている可能性があります。",
                suggestions: [
                    "システム設定 > ネットワーク > 詳細 > プロキシ の設定を確認してください",
                    "VPN・セキュリティソフト・コンテンツフィルタを一時的に無効にして確認してください",
                    "日付と時刻が正しく設定されているか確認してください（証明書エラーの原因になります）",
                ])

        case nil:
            break
        }

        if status == .online {
            var suggestions: [String] = []
            if flags.contains(.localNetworkDenied) { suggestions.append(permissionHint) }
            return Diagnosis(
                headline: "インターネットに正常に接続されています",
                explanation: "\(interface) 経由で、ルーター・インターネット・DNS・Web のすべてに問題なく到達できています。",
                suggestions: suggestions)
        }

        // degraded
        let warnings = stages.filter { $0.status == .warning }
        var suggestions: [String] = []
        if flags.contains(.weakSignal) { suggestions.append("Wi‑Fi の電波が弱くなっています。ルーターに近づくか、障害物を減らしてください") }
        if flags.contains(.packetLoss) { suggestions.append("ルーターとの通信で一部のパケットが失われています。電波状況や他の機器の干渉を確認してください") }
        if flags.contains(.slow) { suggestions.append("回線が混雑している可能性があります。時間をおいて再度確認してください") }
        if flags.contains(.localNetworkDenied) { suggestions.append(permissionHint) }
        return Diagnosis(
            headline: "インターネットは利用できますが、一部に問題があります",
            explanation: warnings.map { "\($0.stage.title): \($0.summary)" }.joined(separator: "\n"),
            suggestions: suggestions)
    }
}
