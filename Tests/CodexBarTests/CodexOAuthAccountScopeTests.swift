import Foundation
import Testing
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite(.serialized)
struct CodexOAuthAccountScopeTests {
    @Test
    func `usage strategy sends the resolved JWT organization account header`() async throws {
        let home = try Self.makeAuthHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "org-from-request")
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: nil,
                      headerFields: nil)
            else {
                throw URLError(.badURL)
            }
            let body = #"""
            {"rate_limit":{"primary_window":{"used_percent":12,"reset_at":1786161204,
            "limit_window_seconds":18000},"secondary_window":null}}
            """#
            return (Data(body.utf8), response)
        }

        let context = Self.context(env: ["CODEX_HOME": home.path])
        let result = try await CodexAuthenticatedHTTPTransport.$overrideForTesting
            .withValue(transport) {
                try await CodexOAuthFetchStrategy().fetch(context)
            }

        #expect(result.usage.primary?.usedPercent == 12)
        #expect(await transport.requests().count == 1)
    }

    @Test
    func `all account scoped OAuth endpoints use the resolved organization account`() async throws {
        let credentials = Self.credentials()
        let transport = ProviderHTTPTransportStub { request in
            let path = request.url?.path ?? ""
            let header = request.value(forHTTPHeaderField: "ChatGPT-Account-Id")
                ?? request.value(forHTTPHeaderField: "ChatGPT-Account-ID")
            #expect(header == "org-from-request")
            if path.contains("rate-limit-reset-credits") {
                let body = #"{"credits":[],"available_count":0}"#
                guard let url = request.url,
                      let response = HTTPURLResponse(
                          url: url,
                          statusCode: 200,
                          httpVersion: nil,
                          headerFields: nil)
                else {
                    throw URLError(.badURL)
                }
                return (Data(body.utf8), response)
            }
            if path.contains("monthly-usage") {
                let body = #"""
                {"current_month_usage":1,"effective_monthly_limit":{"limit":10,
                "enforcement_mode":"HARD_CAP","limit_mode":"amount_credits"}}
                """#
                guard let url = request.url,
                      let response = HTTPURLResponse(
                          url: url,
                          statusCode: 200,
                          httpVersion: nil,
                          headerFields: nil)
                else {
                    throw URLError(.badURL)
                }
                return (Data(body.utf8), response)
            }
            let body = #"{"rate_limit":{"primary_window":null,"secondary_window":null}}"#
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: nil,
                      headerFields: nil)
            else {
                throw URLError(.badURL)
            }
            return (Data(body.utf8), response)
        }

        _ = try await CodexOAuthUsageFetcher.fetchUsage(
            accessToken: credentials.accessToken,
            accountId: credentials.resolvedAccountId,
            env: [:],
            session: transport)
        _ = try await CodexOAuthUsageFetcher.fetchRateLimitResetCredits(
            accessToken: credentials.accessToken,
            accountId: credentials.resolvedAccountId,
            env: [:],
            session: transport)
        _ = try await CodexOAuthUsageFetcher.fetchSpendControlsMonthlyUsage(
            accessToken: credentials.accessToken,
            accountId: #require(credentials.resolvedAccountId),
            env: [:],
            session: transport)

        #expect(await transport.requests().count == 3)
    }

    @Test
    func `workspace lookup uses the resolved organization account`() async throws {
        let credentials = Self.credentials()
        let transport = ProviderHTTPTransportStub { request in
            let header = request.value(forHTTPHeaderField: "ChatGPT-Account-Id")
            #expect(header == "org-from-request")
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: nil,
                      headerFields: nil)
            else {
                throw URLError(.badURL)
            }
            return (Data(#"{"items":[{"id":"org-from-request","name":"Workspace"}]}"#.utf8), response)
        }

        let identity = try await CodexOpenAIWorkspaceResolver.resolve(
            credentials: credentials,
            session: transport)

        #expect(identity?.workspaceAccountID == "org-from-request")
        #expect(identity?.workspaceLabel == "Workspace")
        #expect(await transport.requests().count == 1)
    }

    private static func credentials() -> CodexOAuthCredentials {
        let data = Data(#"{"organizations":[{"id":"org-from-request"}]}"#.utf8)
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return CodexOAuthCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: ["header", encoded, "signature"].joined(separator: "."),
            accountId: " \n",
            lastRefresh: Date())
    }

    private static func makeAuthHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let credentials = Self.credentials()
        let auth: [String: Any] = [
            "last_refresh": ISO8601DateFormatter().string(from: Date()),
            "tokens": [
                "access_token": credentials.accessToken,
                "refresh_token": credentials.refreshToken,
                "id_token": credentials.idToken as Any,
                "account_id": " \n",
            ],
        ]
        try JSONSerialization.data(withJSONObject: auth).write(to: home.appendingPathComponent("auth.json"))
        return home
    }

    private static func context(env: [String: String]) -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .oauth,
            includeCredits: false,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }
}
