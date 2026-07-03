import Foundation
import Testing
@testable import CodexBarCore

struct DeepSeekPlatformSessionTests {
    @Test
    func `session parser accepts cookie header`() throws {
        let session = try #require(DeepSeekCookieHeader.session(from: "session=abc; path=/"))
        #expect(session.cookieHeader == "session=abc; path=/")
        #expect(session.authorizationHeader == nil)
    }

    @Test
    func `session parser accepts bearer authorization header`() throws {
        let session = try #require(DeepSeekCookieHeader.session(from: "Bearer eyJ.test.token"))
        #expect(session.cookieHeader == nil)
        #expect(session.authorizationHeader == "Bearer eyJ.test.token")
    }

    @Test
    func `session parser accepts devtools authorization line`() throws {
        let raw = """
        Authorization: Bearer eyJ.test.token
        Cookie: session=abc
        """
        let session = try #require(DeepSeekCookieHeader.session(from: raw))
        #expect(session.authorizationHeader == "Bearer eyJ.test.token")
        #expect(session.cookieHeader == "session=abc")
    }

    @Test
    func `auth failure payload detection recognizes platform codes`() {
        let payload = Data("""
        {"code":40003,"msg":"Authorization Failed"}
        """.utf8)
        #expect(DeepSeekCookieHeader.isAuthFailurePayload(payload))
    }

    @Test
    func `usage parser maps auth failure code to invalid credentials`() throws {
        let amount = Data("""
        {"code":40003,"msg":"Authorization Failed","data":null}
        """.utf8)
        let cost = Data("""
        {"code":0,"msg":"","data":{"biz_code":0,"biz_data":[]}}
        """.utf8)

        do {
            _ = try DeepSeekUsageFetcher._parseUsageSummaryForTesting(amountData: amount, costData: cost)
            Issue.record("Expected invalid credentials")
        } catch DeepSeekUsageError.invalidCredentials {
            #expect(Bool(true))
        }
    }
}

struct DeepSeekWebEnrichmentResolverTests {
    @Test
    func `explicit env cookie becomes enrichment candidate`() {
        let context = ProviderFetchContext(
            runtime: .cli,
            env: ["DEEPSEEK_COOKIE": "session=abc"],
            settings: ProviderSettingsSnapshot.make(deepseek: .init(cookieSource: .auto, manualCookieHeader: nil)))
        let candidates = DeepSeekWebEnrichmentResolver.candidates(context: context)
        #expect(candidates.count == 1)
        #expect(candidates[0].sourceLabel == "environment")
        #expect(candidates[0].session.cookieHeader == "session=abc")
    }

    @Test
    func `cookie source off yields no candidates`() {
        let context = ProviderFetchContext(
            runtime: .cli,
            env: ["DEEPSEEK_COOKIE": "session=abc"],
            settings: ProviderSettingsSnapshot.make(deepseek: .init(cookieSource: .off, manualCookieHeader: nil)))
        let candidates = DeepSeekWebEnrichmentResolver.candidates(context: context)
        #expect(candidates.isEmpty)
    }
}
