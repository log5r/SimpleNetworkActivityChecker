import Darwin
import Foundation
import Network
import Synchronization

// MARK: - Helpers

/// continuation を一度だけ再開するためのボックス。
nonisolated final class OnceResumer<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, Never>?>

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ value: Value) {
        let pending = continuation.withLock { stored -> CheckedContinuation<Value, Never>? in
            defer { stored = nil }
            return stored
        }
        pending?.resume(returning: value)
    }
}

nonisolated extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}

/// ローカルネットワークへのアクセスが拒否されたために接続できないか。
/// 経路が実際に不成立の場合だけ判定する（評価中の一時的な状態を誤検出しないため）。
nonisolated private func isLocalNetworkDenied(_ connection: NWConnection) -> Bool {
    guard let path = connection.currentPath else { return false }
    return path.status == .unsatisfied && path.unsatisfiedReason == .localNetworkDenied
}

nonisolated private func describe(_ error: NWError) -> String {
    switch error {
    case .posix(let code):
        switch code {
        case .ECONNREFUSED: return "接続が拒否されました"
        case .ETIMEDOUT: return "タイムアウトしました"
        case .EHOSTUNREACH: return "ホストに到達できません (No route to host)"
        case .ENETUNREACH: return "ネットワークに到達できません (Network unreachable)"
        case .ENETDOWN: return "ネットワークがダウンしています"
        case .EHOSTDOWN: return "ホストが応答しません (Host is down)"
        default: return String(cString: strerror(code.rawValue))
        }
    case .dns(let code):
        return "DNS エラー (\(code))"
    case .tls(let status):
        return "TLS エラー (\(status))"
    default:
        return error.localizedDescription
    }
}

// MARK: - TCP

nonisolated enum ProbeOutcome: Sendable {
    /// 接続に成功した
    case connected(latencyMs: Double)
    /// 相手が接続を拒否した（＝ホストまでは到達している）
    case refused(latencyMs: Double)
    /// ローカルネットワークへのアクセスが許可されていない
    case localNetworkDenied
    case failed(String)

    var isReachable: Bool {
        switch self {
        case .connected, .refused: true
        default: false
        }
    }

    var latencyMs: Double? {
        switch self {
        case .connected(let ms), .refused(let ms): ms
        default: nil
        }
    }
}

nonisolated enum TCPProbe {
    static func connect(host: String, port: UInt16, timeout: TimeInterval = 3) async -> ProbeOutcome {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return .failed("不正なポート番号") }
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = Int(timeout.rounded(.up))
            tcp.noDelay = true
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let queue = DispatchQueue(label: "probe.tcp.\(host)")
        let start = ContinuousClock.now

        return await withCheckedContinuation { continuation in
            let once = OnceResumer(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(.connected(latencyMs: start.duration(to: .now).milliseconds))
                    connection.cancel()
                case .waiting(let error), .failed(let error):
                    let elapsed = start.duration(to: .now).milliseconds
                    if isLocalNetworkDenied(connection) {
                        once.resume(.localNetworkDenied)
                    } else if case .posix(.ECONNREFUSED) = error {
                        once.resume(.refused(latencyMs: elapsed))
                    } else {
                        once.resume(.failed(describe(error)))
                    }
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                once.resume(.failed("タイムアウトしました（\(Int(timeout)) 秒）"))
                connection.cancel()
            }
        }
    }
}

// MARK: - ICMP

nonisolated enum ICMPPinger {
    struct Result: Sendable {
        var sent = 0
        var received = 0
        var roundTripTimes: [Double] = []
        var error: String?

        var averageMs: Double? {
            roundTripTimes.isEmpty ? nil : roundTripTimes.reduce(0, +) / Double(roundTripTimes.count)
        }

        var lossPercent: Double {
            sent == 0 ? 100 : Double(sent - received) / Double(sent) * 100
        }
    }

    /// 非特権 ICMP ソケット（SOCK_DGRAM）で Echo Request を送る。ブロッキング処理のため並行実行する。
    @concurrent
    static func ping(_ host: String, count: Int = 3, timeout: TimeInterval = 1) async -> Result {
        var result = Result()

        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &target.sin_addr) == 1 else {
            result.error = "IPv4 アドレスではないため ping を実行できません"
            return result
        }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else {
            result.error = "ICMP ソケットを作成できません (\(String(cString: strerror(errno))))"
            return result
        }
        defer { close(fd) }

        let identifier = UInt16.random(in: 1...UInt16.max)

        for sequence in 0..<count {
            if Task.isCancelled { break }
            var packet = [UInt8](repeating: 0, count: 8 + 24)
            packet[0] = 8 // Echo Request
            packet[4] = UInt8(identifier >> 8)
            packet[5] = UInt8(identifier & 0xFF)
            packet[6] = UInt8(UInt16(sequence) >> 8)
            packet[7] = UInt8(UInt16(sequence) & 0xFF)
            for index in 8..<packet.count { packet[index] = UInt8(truncatingIfNeeded: index) }
            let sum = checksum(packet)
            packet[2] = UInt8(sum >> 8)
            packet[3] = UInt8(sum & 0xFF)

            let sendTime = ContinuousClock.now
            let sentBytes = packet.withUnsafeBytes { buffer in
                withUnsafePointer(to: &target) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sentBytes >= 0 else {
                result.error = "送信できません (\(String(cString: strerror(errno))))"
                continue
            }
            result.sent += 1

            let deadline = sendTime.advanced(by: .milliseconds(Int(timeout * 1000)))
            receiveLoop: while true {
                let remaining = ContinuousClock.now.duration(to: deadline).milliseconds
                guard remaining > 0 else { break }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, Int32(remaining.rounded(.up))) > 0 else { break }

                var buffer = [UInt8](repeating: 0, count: 2048)
                var from = sockaddr_in()
                var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let received = withUnsafeMutablePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLength)
                    }
                }
                guard received > 0 else { break }

                // macOS の SOCK_DGRAM ICMP は IP ヘッダ付きで返る
                var offset = 0
                if received >= 20, buffer[0] >> 4 == 4 { offset = Int(buffer[0] & 0x0F) * 4 }
                guard received >= offset + 8,
                      buffer[offset] == 0, // Echo Reply
                      from.sin_addr.s_addr == target.sin_addr.s_addr else { continue }
                let replySequence = UInt16(buffer[offset + 6]) << 8 | UInt16(buffer[offset + 7])
                guard replySequence == UInt16(sequence) else { continue }

                result.received += 1
                result.roundTripTimes.append(sendTime.duration(to: .now).milliseconds)
                break receiveLoop
            }
        }
        return result
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }
}

// MARK: - DNS

nonisolated enum DNSOutcome: Sendable {
    case answered(latencyMs: Double, answerCount: Int)
    case serverError(code: Int, latencyMs: Double)
    case localNetworkDenied
    case failed(String)

    static func rcodeDescription(_ code: Int) -> String {
        switch code {
        case 1: "FORMERR（問い合わせ形式エラー）"
        case 2: "SERVFAIL（サーバー障害）"
        case 3: "NXDOMAIN（名前が存在しない）"
        case 5: "REFUSED（問い合わせ拒否）"
        default: "RCODE \(code)"
        }
    }
}

nonisolated enum DNSProbe {
    /// 設定済みの DNS サーバーへ UDP で直接 A レコードを問い合わせる（キャッシュの影響を受けない）。
    static func query(server: String, name: String = "www.apple.com", timeout: TimeInterval = 3) async -> DNSOutcome {
        let identifier = UInt16.random(in: 0...UInt16.max)
        var message: [UInt8] = [
            UInt8(identifier >> 8), UInt8(identifier & 0xFF),
            0x01, 0x00, // 再帰問い合わせ
            0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        for label in name.split(separator: ".") {
            message.append(UInt8(label.utf8.count))
            message.append(contentsOf: label.utf8)
        }
        message.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01]) // QTYPE=A, QCLASS=IN

        let connection = NWConnection(host: NWEndpoint.Host(server), port: 53, using: .udp)
        let queue = DispatchQueue(label: "probe.dns.\(server)")
        let start = ContinuousClock.now
        let payload = Data(message)

        return await withCheckedContinuation { continuation in
            let once = OnceResumer(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: payload, completion: .contentProcessed { error in
                        if let error { once.resume(.failed(describe(error))); connection.cancel() }
                    })
                    connection.receiveMessage { data, _, _, error in
                        defer { connection.cancel() }
                        if let error { once.resume(.failed(describe(error))); return }
                        guard let data, data.count >= 12 else { once.resume(.failed("不正な応答")); return }
                        let bytes = [UInt8](data)
                        guard UInt16(bytes[0]) << 8 | UInt16(bytes[1]) == identifier, bytes[2] & 0x80 != 0 else {
                            once.resume(.failed("不正な応答"))
                            return
                        }
                        let latency = start.duration(to: .now).milliseconds
                        let rcode = Int(bytes[3] & 0x0F)
                        if rcode == 0 {
                            once.resume(.answered(latencyMs: latency, answerCount: Int(bytes[6]) << 8 | Int(bytes[7])))
                        } else {
                            once.resume(.serverError(code: rcode, latencyMs: latency))
                        }
                    }
                case .waiting(let error), .failed(let error):
                    if isLocalNetworkDenied(connection) {
                        once.resume(.localNetworkDenied)
                    } else {
                        once.resume(.failed(describe(error)))
                    }
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                once.resume(.failed("応答がありません（\(Int(timeout)) 秒）"))
                connection.cancel()
            }
        }
    }

    /// システムのリゾルバ（getaddrinfo）で名前解決する。結果はキャッシュされている可能性がある。
    static func systemResolve(_ host: String, timeout: TimeInterval = 4) async -> ProbeOutcome {
        await withCheckedContinuation { continuation in
            let once = OnceResumer(continuation)
            let start = ContinuousClock.now
            Thread.detachNewThread {
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                var info: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, "443", &hints, &info)
                if let info { freeaddrinfo(info) }
                if status == 0 {
                    once.resume(.connected(latencyMs: start.duration(to: .now).milliseconds))
                } else {
                    once.resume(.failed(String(cString: gai_strerror(status))))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(.failed("タイムアウトしました"))
            }
        }
    }
}

// MARK: - HTTP

nonisolated enum HTTPOutcome: Sendable {
    case success(latencyMs: Double)
    case unexpectedResponse(statusCode: Int, latencyMs: Double)
    case failed(code: URLError.Code?, message: String)
}

nonisolated enum CaptivePortalOutcome: Sendable {
    case notCaptive
    case captive(redirect: String?)
    case failed(String)
}

nonisolated enum HTTPProbe {
    struct Target: Sendable {
        var url: URL
        var expectedStatus: Int
        var expectedBody: String?
    }

    static let targets: [Target] = [
        Target(url: URL(string: "https://www.apple.com/library/test/success.html")!, expectedStatus: 200, expectedBody: "Success"),
        Target(url: URL(string: "https://www.google.com/generate_204")!, expectedStatus: 204, expectedBody: nil),
    ]

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static func fetch(_ target: Target) async -> HTTPOutcome {
        var request = URLRequest(url: target.url)
        request.httpMethod = "GET"
        request.setValue("SimpleNetworkActivityChecker", forHTTPHeaderField: "User-Agent")
        let start = ContinuousClock.now
        do {
            let (data, response) = try await session.data(for: request)
            let latency = start.duration(to: .now).milliseconds
            guard let http = response as? HTTPURLResponse else {
                return .failed(code: nil, message: "HTTP 以外の応答")
            }
            let bodyMatches = target.expectedBody.map { String(decoding: data, as: UTF8.self).contains($0) } ?? true
            if http.statusCode == target.expectedStatus, bodyMatches {
                return .success(latencyMs: latency)
            }
            return .unexpectedResponse(statusCode: http.statusCode, latencyMs: latency)
        } catch let error as URLError {
            return .failed(code: error.code, message: error.localizedDescription)
        } catch {
            return .failed(code: nil, message: error.localizedDescription)
        }
    }

    /// 暗号化しない HTTP で captive.apple.com にアクセスし、応答が書き換えられていないかを確認する。
    /// ATS の制約を受けないよう Network.framework で直接 HTTP リクエストを送る。
    static func captivePortalCheck(timeout: TimeInterval = 5) async -> CaptivePortalOutcome {
        let host = "captive.apple.com"
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 80, using: .tcp)
        let queue = DispatchQueue(label: "probe.captive")
        let request = Data("GET /hotspot-detect.html HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: CaptiveNetworkSupport\r\nConnection: close\r\n\r\n".utf8)
        let buffer = Mutex(Data())

        return await withCheckedContinuation { continuation in
            let once = OnceResumer(continuation)

            @Sendable func evaluate() {
                let text = String(decoding: buffer.withLock { $0 }, as: UTF8.self)
                guard !text.isEmpty else { once.resume(.failed("応答がありません")); return }
                if text.contains("<BODY>Success</BODY>") || text.contains("Success") {
                    once.resume(.notCaptive)
                } else {
                    let location = text.components(separatedBy: "\r\n")
                        .first { $0.lowercased().hasPrefix("location:") }
                        .map { $0.dropFirst("location:".count).trimmingCharacters(in: .whitespaces) }
                    once.resume(.captive(redirect: location))
                }
            }

            @Sendable func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    if let data { buffer.withLock { $0.append(data) } }
                    let size = buffer.withLock { $0.count }
                    if isComplete || error != nil || size > 256_000 {
                        evaluate()
                        connection.cancel()
                    } else {
                        receive()
                    }
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: request, completion: .contentProcessed { _ in })
                    receive()
                case .waiting(let error), .failed(let error):
                    once.resume(.failed(describe(error)))
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if buffer.withLock({ $0.isEmpty }) {
                    once.resume(.failed("タイムアウトしました"))
                } else {
                    evaluate()
                }
                connection.cancel()
            }
        }
    }
}
