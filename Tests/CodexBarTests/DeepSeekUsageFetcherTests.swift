import Foundation
import Testing
@testable import CodexBarCore

struct DeepSeekUsageFetcherTests {
    private struct TimeoutError: Error {}

    private actor SummaryCancellationProbe {
        private var started = false
        private var cancelled = false
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []

        func markStarted() {
            self.started = true
            for waiter in self.startedWaiters {
                waiter.resume()
            }
            self.startedWaiters.removeAll()
        }

        func waitUntilStarted() async {
            if self.started { return }
            await withCheckedContinuation { continuation in
                self.startedWaiters.append(continuation)
            }
        }

        func markCancelled() {
            self.cancelled = true
        }

        func wasCancelled() -> Bool {
            self.cancelled
        }
    }

    private static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T) async throws -> T
    {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimeoutError()
            }

            let result = try await group.next()
            group.cancelAll()
            guard let result else { throw TimeoutError() }
            return result
        }
    }

    private static let sampleBalanceJSON = """
    {
      "is_available": true,
      "balance_infos": [
        {
          "currency": "USD",
          "total_balance": "50.00",
          "granted_balance": "10.00",
          "topped_up_balance": "40.00"
        }
      ]
    }
    """

    private static func sampleSummary(updatedAt: Date = Date()) -> DeepSeekUsageSummary {
        DeepSeekUsageSummary(
            todayTokens: 123,
            currentMonthTokens: 456,
            todayCost: 1.23,
            currentMonthCost: 4.56,
            requestCount: 7,
            currentMonthRequestCount: 8,
            topModel: "deepseek-v4-flash",
            categoryBreakdown: [
                DeepSeekCategoryBreakdown(category: .promptCacheHitToken, tokens: 123, cost: 1.23),
            ],
            daily: [],
            currency: "USD",
            updatedAt: updatedAt)
    }

    @Test
    func `parses USD balance response`() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "USD",
              "total_balance": "50.00",
              "granted_balance": "10.00",
              "topped_up_balance": "40.00"
            }
          ]
        }
        """
        let snapshot = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        #expect(snapshot.isAvailable == true)
        #expect(snapshot.currency == "USD")
        #expect(snapshot.totalBalance == 50.0)
        #expect(snapshot.grantedBalance == 10.0)
        #expect(snapshot.toppedUpBalance == 40.0)
    }

    @Test
    func `parses CNY balance response`() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "CNY",
              "total_balance": "110.00",
              "granted_balance": "10.00",
              "topped_up_balance": "100.00"
            }
          ]
        }
        """
        let snapshot = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        #expect(snapshot.currency == "CNY")
        #expect(snapshot.totalBalance == 110.0)
        #expect(snapshot.toppedUpBalance == 100.0)
    }

    @Test
    func `prefers USD when both currencies present`() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "CNY",
              "total_balance": "100.00",
              "granted_balance": "0.00",
              "topped_up_balance": "100.00"
            },
            {
              "currency": "USD",
              "total_balance": "20.00",
              "granted_balance": "5.00",
              "topped_up_balance": "15.00"
            }
          ]
        }
        """
        let snapshot = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        #expect(snapshot.currency == "USD")
        #expect(snapshot.totalBalance == 20.0)
    }

    @Test
    func `prefers positive CNY balance over empty USD balance`() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "USD",
              "total_balance": "0.00",
              "granted_balance": "0.00",
              "topped_up_balance": "0.00"
            },
            {
              "currency": "CNY",
              "total_balance": "100.00",
              "granted_balance": "0.00",
              "topped_up_balance": "100.00"
            }
          ]
        }
        """
        let snapshot = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.currency == "CNY")
        #expect(snapshot.totalBalance == 100.0)
        #expect(usage.primary?.resetDescription?.contains("¥100.00") == true)
    }

    @Test
    func `zero balance prompts top up even when unavailable`() throws {
        let json = """
        {
          "is_available": false,
          "balance_infos": [
            {
              "currency": "USD",
              "total_balance": "0.00",
              "granted_balance": "0.00",
              "topped_up_balance": "0.00"
            }
          ]
        }
        """
        let snapshot = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        #expect(snapshot.isAvailable == false)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetDescription == "$0.00 — add credits at platform.deepseek.com")
        #expect(usage.identity?.loginMethod == nil)
    }

    @Test
    func `full bar when balance available`() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "USD",
              "total_balance": "5.00",
              "granted_balance": "0.00",
              "topped_up_balance": "5.00"
            }
          ]
        }
        """
        let snapshot = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 0)
        #expect(usage.primary?.resetDescription?.contains("$5.00") == true)
        #expect(usage.identity?.loginMethod == nil)
    }

    @Test
    func `throws on malformed balance string`() {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "USD",
              "total_balance": "not-a-number",
              "granted_balance": "0.00",
              "topped_up_balance": "0.00"
            }
          ]
        }
        """
        #expect {
            _ = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        } throws: { error in
            guard case DeepSeekUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `empty balance_infos returns unavailable snapshot`() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": []
        }
        """
        let snapshot = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        #expect(snapshot.isAvailable == false)
        #expect(snapshot.totalBalance == 0.0)
    }

    @Test
    func `throws on invalid JSON root`() {
        let json = "[{ \"is_available\": true }]"
        #expect {
            _ = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        } throws: { error in
            guard case DeepSeekUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `balance description includes paid and granted breakdown`() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "USD",
              "total_balance": "50.00",
              "granted_balance": "10.00",
              "topped_up_balance": "40.00"
            }
          ]
        }
        """
        let snapshot = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        let usage = snapshot.toUsageSnapshot()
        let detail = usage.primary?.resetDescription ?? ""
        #expect(detail.contains("$50.00"))
        #expect(detail.contains("$40.00"))
        #expect(detail.contains("$10.00"))
    }

    @Test
    func `CNY balance uses yen symbol`() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "CNY",
              "total_balance": "100.00",
              "granted_balance": "0.00",
              "topped_up_balance": "100.00"
            }
          ]
        }
        """
        let snapshot = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        let usage = snapshot.toUsageSnapshot()
        let detail = usage.primary?.resetDescription ?? ""
        #expect(detail.contains("¥"))
    }

    @Test
    func `balance snapshot has nil usage summary`() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "USD",
              "total_balance": "50.00",
              "granted_balance": "10.00",
              "topped_up_balance": "40.00"
            }
          ]
        }
        """
        let snapshot = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.deepseekUsage == nil)
    }

    @Test
    func `balance returns promptly when optional usage summary is slow`() async throws {
        let probe = SummaryCancellationProbe()
        let snapshot = try await Self.withTimeout(.seconds(10)) {
            try await DeepSeekUsageFetcher._fetchUsageForTesting(
                apiKey: "test-key",
                includeOptionalUsage: true,
                optionalSummaryJoinGrace: .milliseconds(50),
                fetchBalanceData: { _ in
                    Data(Self.sampleBalanceJSON.utf8)
                },
                fetchSummary: { _ in
                    await probe.markStarted()
                    do {
                        try await Task.sleep(for: .seconds(60))
                        return Self.sampleSummary()
                    } catch is CancellationError {
                        await probe.markCancelled()
                        throw CancellationError()
                    }
                })
        }

        #expect(snapshot.totalBalance == 50.0)
        #expect(snapshot.usageSummary == nil)
        #expect(await probe.wasCancelled())
    }

    @Test
    func `balance returns when optional usage summary fails closed`() async throws {
        let snapshot = try await DeepSeekUsageFetcher._fetchUsageForTesting(
            apiKey: "test-key",
            includeOptionalUsage: true,
            optionalSummaryJoinGrace: .seconds(2),
            fetchBalanceData: { _ in
                Data(Self.sampleBalanceJSON.utf8)
            },
            fetchSummary: { _ in
                throw DeepSeekUsageError.networkError("simulated failure")
            })

        #expect(snapshot.totalBalance == 50.0)
        #expect(snapshot.usageSummary == nil)
    }

    @Test
    func `cancels optional usage summary when balance fetch fails`() async throws {
        let probe = SummaryCancellationProbe()

        do {
            _ = try await DeepSeekUsageFetcher._fetchUsageForTesting(
                apiKey: "test-key",
                includeOptionalUsage: true,
                optionalSummaryJoinGrace: .seconds(2),
                fetchBalanceData: { _ in
                    await probe.waitUntilStarted()
                    throw DeepSeekUsageError.networkError("simulated balance failure")
                },
                fetchSummary: { _ in
                    await probe.markStarted()
                    do {
                        try await Task.sleep(for: .seconds(1))
                        return Self.sampleSummary()
                    } catch is CancellationError {
                        await probe.markCancelled()
                        throw DeepSeekUsageError.networkError("cancelled")
                    }
                })
            Issue.record("Expected balance failure")
        } catch DeepSeekUsageError.networkError {
            try await Task.sleep(for: .milliseconds(100))
            #expect(await probe.wasCancelled())
        }
    }

    @Test
    func `cancels optional usage summary when balance parsing fails`() async throws {
        let probe = SummaryCancellationProbe()

        do {
            _ = try await DeepSeekUsageFetcher._fetchUsageForTesting(
                apiKey: "test-key",
                includeOptionalUsage: true,
                optionalSummaryJoinGrace: .seconds(2),
                fetchBalanceData: { _ in
                    await probe.waitUntilStarted()
                    return Data("{\"is_available\":true,\"balance_infos\":[".utf8)
                },
                fetchSummary: { _ in
                    await probe.markStarted()
                    do {
                        try await Task.sleep(for: .seconds(1))
                        return Self.sampleSummary()
                    } catch is CancellationError {
                        await probe.markCancelled()
                        throw DeepSeekUsageError.networkError("cancelled")
                    }
                })
            Issue.record("Expected balance parse failure")
        } catch DeepSeekUsageError.parseFailed {
            try await Task.sleep(for: .milliseconds(100))
            #expect(await probe.wasCancelled())
        }
    }

    @Test
    func `parent cancellation propagates while waiting for optional usage summary`() async throws {
        let probe = SummaryCancellationProbe()
        let task = Task {
            try await DeepSeekUsageFetcher._fetchUsageForTesting(
                apiKey: "test-key",
                includeOptionalUsage: true,
                optionalSummaryJoinGrace: .seconds(30),
                fetchBalanceData: { _ in
                    Data(Self.sampleBalanceJSON.utf8)
                },
                fetchSummary: { _ in
                    await probe.markStarted()
                    do {
                        try await Task.sleep(for: .seconds(60))
                        return Self.sampleSummary()
                    } catch is CancellationError {
                        await probe.markCancelled()
                        throw CancellationError()
                    }
                })
        }

        await probe.waitUntilStarted()
        task.cancel()

        do {
            _ = try await Self.withTimeout(.seconds(10)) {
                try await task.value
            }
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(await probe.wasCancelled())
        }
    }

    @Test
    func `usage period defaults to Gregorian API calendar`() throws {
        let date = try #require(Self.utcDate(year: 2026, month: 5, day: 26))
        let period = try DeepSeekUsageFetcher._apiUsagePeriodForTesting(now: date)

        #expect(period.month == 5)
        #expect(period.year == 2026)
    }

    @Test
    func `usage period supports injected test calendar`() throws {
        var calendar = Calendar(identifier: .buddhist)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let date = try #require(Self.utcDate(year: 2026, month: 5, day: 26))
        let period = try DeepSeekUsageFetcher._apiUsagePeriodForTesting(now: date, calendar: calendar)

        #expect(period.month == 5)
        #expect(period.year == 2569)
    }

    @Test
    func `production path can populate usage summary when optional fetch succeeds`() async throws {
        let expected = Self.sampleSummary()
        let snapshot = try await DeepSeekUsageFetcher._fetchUsageForTesting(
            apiKey: "test-key",
            includeOptionalUsage: true,
            optionalSummaryJoinGrace: .seconds(2),
            fetchBalanceData: { _ in
                Data(Self.sampleBalanceJSON.utf8)
            },
            fetchSummary: { _ in
                expected
            })

        #expect(snapshot.totalBalance == 50.0)
        #expect(snapshot.usageSummary == expected)
    }

    private static func utcDate(year: Int, month: Int, day: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    // MARK: - Application-level error detection (regression for #1166 silent failure)

    @Test
    func `app-level 40003 invalid token raises sessionCookieRequired`() {
        let body = #"{"code":40003,"msg":"Authorization Failed (invalid token)","data":null}"#

        do {
            try DeepSeekUsageFetcher._throwIfApplicationErrorForTesting(
                data: Data(body.utf8),
                endpoint: "amount")
            Issue.record("Expected sessionCookieRequired")
        } catch let error as DeepSeekUsageError {
            guard case let .sessionCookieRequired(endpoint, message) = error else {
                Issue.record("Wrong error case: \(error)")
                return
            }
            #expect(endpoint == "amount")
            #expect(message.contains("invalid token"))
            #expect(error.isSessionCookieRequired)
            #expect(error.userHint?.contains("Sign in to platform.deepseek.com") == true)
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test
    func `app-level 0 success body does not raise`() throws {
        let body = #"{"code":0,"msg":"","data":{"biz_code":0}}"#
        try DeepSeekUsageFetcher._throwIfApplicationErrorForTesting(
            data: Data(body.utf8),
            endpoint: "amount")
    }

    @Test
    func `app-level body without code field does not raise`() throws {
        // Real parser fixtures don't always set top-level `code`; we should
        // not raise here and let the typed parser deal with the body.
        let body = #"{"data":{"biz_data":{}}}"#
        try DeepSeekUsageFetcher._throwIfApplicationErrorForTesting(
            data: Data(body.utf8),
            endpoint: "cost")
    }

    @Test
    func `non-JSON body does not raise`() throws {
        // WAF or HTML error pages must not be misclassified as DeepSeek app errors.
        let body = "<!DOCTYPE html><html>blocked</html>"
        try DeepSeekUsageFetcher._throwIfApplicationErrorForTesting(
            data: Data(body.utf8),
            endpoint: "amount")
    }

    @Test
    func `unrelated app-level non-zero code raises generic apiError`() {
        let body = #"{"code":50000,"msg":"server error","data":null}"#

        do {
            try DeepSeekUsageFetcher._throwIfApplicationErrorForTesting(
                data: Data(body.utf8),
                endpoint: "cost")
            Issue.record("Expected apiError")
        } catch let error as DeepSeekUsageError {
            guard case let .apiError(message) = error else {
                Issue.record("Wrong error case: \(error)")
                return
            }
            #expect(message.contains("50000"))
            #expect(message.contains("server error"))
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test
    func `summary failure is captured on snapshot when optional fetch throws`() async throws {
        // When the optional usage summary throws, balance must still come back,
        // and the failure must be recorded on the snapshot so the UI can show
        // a hint (e.g. "Sign in to platform.deepseek.com") instead of
        // silently hiding the dashboard.
        let snapshot = try await DeepSeekUsageFetcher._fetchUsageForTesting(
            apiKey: "test-key",
            includeOptionalUsage: true,
            optionalSummaryJoinGrace: .seconds(2),
            fetchBalanceData: { _ in
                Data(Self.sampleBalanceJSON.utf8)
            },
            fetchSummary: { _ in
                throw DeepSeekUsageError.sessionCookieRequired(
                    endpoint: "amount",
                    message: "Sign in to platform.deepseek.com (server: invalid token)")
            })

        #expect(snapshot.totalBalance == 50.0)
        #expect(snapshot.usageSummary == nil)
        #expect(snapshot.summaryFailure?.isSessionCookieRequired == true)
        #expect(snapshot.summaryFailure?.userHint?.contains("Sign in to platform.deepseek.com") == true)

        // toUsageSnapshot should propagate the failure.
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.deepseekSummaryError?.isSessionCookieRequired == true)
    }

    @Test
    func `integration platform 40003 raises sessionCookieRequired via URL stub`() async throws {
        // The platform.deepseek.com endpoints return HTTP 200 with an app-level
        // error body. The fetcher must surface that as sessionCookieRequired so
        // the UI can show a hint instead of silently hiding the dashboard.
        DeepSeekAppErrorStubURLProtocol.handler = { request in
            guard let url = request.url, url.host == "platform.deepseek.com" else {
                throw URLError(.unsupportedURL)
            }
            let body = #"{"code":40003,"msg":"Authorization Failed (invalid token)","data":null}"#
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (response, Data(body.utf8))
        }
        let registered = URLProtocol.registerClass(DeepSeekAppErrorStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(DeepSeekAppErrorStubURLProtocol.self)
            }
            DeepSeekAppErrorStubURLProtocol.handler = nil
        }

        do {
            _ = try await DeepSeekUsageFetcher.fetchUsageSummary(apiKey: "test-key")
            Issue.record("Expected sessionCookieRequired")
        } catch let error as DeepSeekUsageError {
            guard case let .sessionCookieRequired(endpoint, _) = error else {
                Issue.record("Wrong error: \(error)")
                return
            }
            #expect(endpoint == "amount")
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    /// Live-network smoke test against the real DeepSeek endpoints. Only runs
    /// when `DEEPSEEK_LIVE_TEST_KEY` is set in the environment, so the regular
    /// `swift test` run does not hit production. Confirms the fetcher raises
    /// `sessionCookieRequired` with the real platform error response.
    @Test
    func `live platform endpoint raises sessionCookieRequired for bearer-only key`() async throws {
        guard let key = ProcessInfo.processInfo.environment["DEEPSEEK_LIVE_TEST_KEY"],
              !key.isEmpty
        else {
            // Skip silently — the regular test run has no live key.
            return
        }

        do {
            _ = try await DeepSeekUsageFetcher.fetchUsageSummary(apiKey: key)
            Issue.record("Expected sessionCookieRequired against live platform endpoint")
        } catch let error as DeepSeekUsageError {
            guard case let .sessionCookieRequired(endpoint, message) = error else {
                Issue.record("Wrong error: \(error)")
                return
            }
            #expect(endpoint == "amount")
            #expect(message.contains("platform.deepseek.com"))
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }
}

private final class DeepSeekAppErrorStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "platform.deepseek.com"
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
