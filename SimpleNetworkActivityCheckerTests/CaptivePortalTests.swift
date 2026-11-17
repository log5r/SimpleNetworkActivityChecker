import Foundation
import Testing
@testable import SimpleNetworkActivityChecker

/// captive.apple.com への HTTP 応答の判定と、その結果を使った原因箇所の判定の確認。
struct CaptivePortalTests {
    private let successBody = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"

    private func classify(_ text: String, closed: Bool = true) -> CaptivePortalOutcome {
        HTTPProbe.classifyCaptivePortalResponse(Data(text.utf8), connectionClosed: closed)
    }

    private func isFailed(_ outcome: CaptivePortalOutcome) -> Bool {
        if case .failed = outcome { true } else { false }
    }

    // MARK: Not captive / inconclusive

    @Test func successBodyIsNotCaptive() {
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(successBody.utf8.count)\r\n\r\n\(successBody)"
        #expect(classify(response) == .notCaptive)
        // 接続を閉じていなくても、Content-Length 分を受け取っていれば完全な応答
        #expect(classify(response, closed: false) == .notCaptive)
    }

    @Test func chunkedSuccessBodyIsNotCaptive() {
        let response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10\r\n<HTML><HEAD><TIT\r\n\(String(successBody.utf8.count - 16, radix: 16))\r\n\(successBody.dropFirst(16))\r\n0\r\n\r\n"
        #expect(classify(response, closed: false) == .notCaptive)
    }

    @Test func serverErrorIsNotCaptive() {
        let body = "<html><body>Service Unavailable</body></html>"
        let outcome = classify("HTTP/1.1 503 Service Unavailable\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        #expect(isFailed(outcome))
    }

    @Test func firewallDenialIsNotCaptive() {
        let body = "<html><body>Access denied by policy</body></html>"
        #expect(isFailed(classify("HTTP/1.1 403 Forbidden\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")))
    }

    @Test func headersOnlyResponseIsNotCaptive() {
        // ヘッダーの途中でタイムアウト
        #expect(isFailed(classify("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n", closed: false)))
        // ヘッダーは届いたが本文が届く前にタイムアウト
        #expect(isFailed(classify("HTTP/1.1 200 OK\r\nContent-Length: 68\r\n\r\n", closed: false)))
        #expect(isFailed(classify("HTTP/1.1 200 OK\r\nContent-Length: 68\r\n\r\n<HTML><HEAD>", closed: false)))
        // 長さの指定がなく、接続も閉じられていない
        #expect(isFailed(classify("HTTP/1.1 200 OK\r\n\r\n<HTML><HEAD>", closed: false)))
        // chunked の最後のチャンクが届いていない
        #expect(isFailed(classify("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10\r\n<HTML><HEAD><TIT\r\n", closed: false)))
    }

    @Test func emptyOrMalformedResponseIsNotCaptive() {
        #expect(isFailed(classify("")))
        #expect(isFailed(classify("garbage\r\n\r\n")))
    }

    @Test func redirectToSameHostIsNotCaptive() {
        #expect(isFailed(classify("HTTP/1.1 301 Moved Permanently\r\nLocation: /hotspot-detect.html\r\nContent-Length: 0\r\n\r\n")))
        #expect(isFailed(classify("HTTP/1.1 302 Found\r\nLocation: http://captive.apple.com/other\r\nContent-Length: 0\r\n\r\n")))
        #expect(isFailed(classify("HTTP/1.1 302 Found\r\nContent-Length: 0\r\n\r\n")))
    }

    // MARK: Captive

    @Test func redirectToAnotherHostIsCaptive() {
        let response = "HTTP/1.1 302 Found\r\nLocation: http://portal.example.net/login?next=1\r\nContent-Length: 0\r\n\r\n"
        #expect(classify(response, closed: false) == .captive(redirect: "http://portal.example.net/login?next=1"))
    }

    @Test func otherBodyWithOKIsCaptive() {
        let body = "<html><body><form>Please sign in</form></body></html>"
        #expect(classify("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)") == .captive(redirect: nil))
        // 長さの指定がなくても、接続が閉じられていれば完全な応答
        #expect(classify("HTTP/1.0 200 OK\r\n\r\n\(body)", closed: true) == .captive(redirect: nil))
    }

    @Test func networkAuthenticationRequiredIsCaptive() {
        #expect(classify("HTTP/1.1 511 Network Authentication Required\r\nContent-Length: 0\r\n\r\n") == .captive(redirect: nil))
    }

    // MARK: evaluate

    private func stages(webFlags: [StageFlag]) -> [StageResult] {
        [
            StageResult(stage: .link, status: .passed, summary: ""),
            StageResult(stage: .address, status: .passed, summary: ""),
            StageResult(stage: .gateway, status: .failed, summary: ""),
            StageResult(stage: .internet, status: .failed, summary: ""),
            StageResult(stage: .dns, status: .failed, summary: ""),
            StageResult(stage: .web, status: .failed, summary: "", flags: webFlags),
        ]
    }

    @Test func evaluateKeepsEarlierFailureWithoutCaptiveEvidence() {
        let (status, failed, _) = NetworkDiagnostician.evaluate(stages(webFlags: []))
        #expect(status == .offline)
        #expect(failed == .gateway)
    }

    @Test func evaluatePrefersCaptivePortalWithEvidence() {
        let (status, failed, _) = NetworkDiagnostician.evaluate(stages(webFlags: [.captivePortal]))
        #expect(status == .offline)
        #expect(failed == .web)
    }
}
