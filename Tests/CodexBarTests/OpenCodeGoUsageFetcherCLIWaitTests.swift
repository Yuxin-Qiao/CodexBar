import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct OpenCodeGoUsageFetcherCLIWaitTests {
    private struct UsageWindow {
        let percent: Double
        let resetInSec: Int
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenCodeGoCLIWaitStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test
    func `cli wait policy includes slow but successful zen balance`() async throws {
        defer {
            OpenCodeGoCLIWaitStubURLProtocol.handler = nil
        }

        OpenCodeGoCLIWaitStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/workspace/wrk_TEST123" {
                Thread.sleep(forTimeInterval: 1)
                return Self.makeResponse(
                    url: url,
                    body: #"<html><body><h2>現在の残高 $98.76</h2></body></html>"#,
                    statusCode: 200,
                    contentType: "text/html")
            }
            return Self.makeResponse(
                url: url,
                body: Self.goUsagePageHTML(
                    workspaceID: "wrk_TEST123",
                    rolling: UsageWindow(percent: 17, resetInSec: 600),
                    weekly: UsageWindow(percent: 75, resetInSec: 7200),
                    monthly: nil),
                statusCode: 200,
                contentType: "text/html")
        }

        let start = ContinuousClock.now
        let snapshot = try await OpenCodeGoUsageFetcher.fetchUsage(
            cookieHeader: "auth=test",
            timeout: 60,
            workspaceIDOverride: "wrk_TEST123",
            waitForZenBalance: true,
            session: self.makeSession())
        let elapsed = start.duration(to: ContinuousClock.now)

        #expect(snapshot.rollingUsagePercent == 17)
        #expect(snapshot.zenBalanceUSD == 98.76)
        #expect(elapsed >= .milliseconds(900))
    }

    @Test
    func `cli wait policy keeps subscription result when balance fetch fails`() async throws {
        defer {
            OpenCodeGoCLIWaitStubURLProtocol.handler = nil
        }

        OpenCodeGoCLIWaitStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/workspace/wrk_TEST123" {
                throw URLError(.timedOut)
            }
            return Self.makeResponse(
                url: url,
                body: Self.goUsagePageHTML(
                    workspaceID: "wrk_TEST123",
                    rolling: UsageWindow(percent: 17, resetInSec: 600),
                    weekly: UsageWindow(percent: 75, resetInSec: 7200),
                    monthly: nil),
                statusCode: 200,
                contentType: "text/html")
        }

        let snapshot = try await OpenCodeGoUsageFetcher.fetchUsage(
            cookieHeader: "auth=test",
            timeout: 60,
            workspaceIDOverride: "wrk_TEST123",
            waitForZenBalance: true,
            session: self.makeSession())

        #expect(snapshot.rollingUsagePercent == 17)
        #expect(snapshot.zenBalanceUSD == nil)
    }

    @Test
    func `cli wait policy keeps configured timeout when zen balance becomes required`() async throws {
        defer {
            OpenCodeGoCLIWaitStubURLProtocol.handler = nil
        }

        var rootTimeout: TimeInterval?
        OpenCodeGoCLIWaitStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/workspace/wrk_TEST123" {
                rootTimeout = request.timeoutInterval
                return Self.makeResponse(
                    url: url,
                    body: #"<html><body><h2>Current balance $17.25</h2></body></html>"#,
                    statusCode: 200,
                    contentType: "text/html")
            }
            return Self.makeResponse(
                url: url,
                body: #"<script>rollingUsage:{usagePercent:12}</script>"#,
                statusCode: 200,
                contentType: "text/html")
        }

        let snapshot = try await OpenCodeGoUsageFetcher.fetchUsage(
            cookieHeader: "auth=test",
            timeout: 60,
            workspaceIDOverride: "wrk_TEST123",
            waitForZenBalance: true,
            session: self.makeSession())

        #expect(snapshot.isBalanceOnly)
        #expect(snapshot.zenBalanceUSD == 17.25)
        #expect(rootTimeout == 60)
    }

    private static func goUsagePageHTML(
        workspaceID: String,
        rolling: UsageWindow,
        weekly: UsageWindow,
        monthly: UsageWindow?) -> String
    {
        let monthlyField: String? = if let monthly {
            #"monthlyUsage:{status:"ok",resetInSec:\#(monthly.resetInSec),usagePercent:\#(monthly.percent)}"#
        } else {
            nil
        }

        let usageFields = [
            #"rollingUsage:{status:"ok",resetInSec:\#(rolling.resetInSec),usagePercent:\#(rolling.percent)}"#,
            #"weeklyUsage:{status:"ok",resetInSec:\#(weekly.resetInSec),usagePercent:\#(weekly.percent)}"#,
            monthlyField,
        ]
            .compactMap(\.self)
            .joined(separator: ",")

        return """
        <!DOCTYPE html>
        <html>
        <body>
        <script>
        _$HY.r["lite.subscription.get[\\"\(workspaceID)\\"]"]=$R[17]=$R[2]($R[18]={p:0,s:0,f:0});
        $R[24]($R[18],$R[27]={mine:!0,useBalance:!1,\(usageFields)});
        </script>
        </body>
        </html>
        """
    }

    private static func makeResponse(
        url: URL,
        body: String,
        statusCode: Int,
        contentType: String) -> (HTTPURLResponse, Data)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType])!
        return (response, Data(body.utf8))
    }
}

private final class OpenCodeGoCLIWaitStubURLProtocol: URLProtocol {
    private static let handlerBox = LockIsolated<((URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { Self.handlerBox.value }
        set { Self.handlerBox.setValue(newValue) }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "opencode.ai"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
