import Foundation
import Testing
@testable import CodexBarCore

struct CodexOAuthCredentialReadTests {
    @Test
    func `missing auth json maps to a not found credential error`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let error = #expect(throws: CodexOAuthCredentialsError.self) {
            try CodexOAuthCredentialsStore.loadOAuthTokens(env: ["CODEX_HOME": home.path])
        }
        guard case .notFound = error else {
            Issue.record("Expected a missing auth file to remain distinguishable")
            return
        }
    }

    @Test
    func `unreadable auth json maps to an unreadable credential error`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-unreadable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("auth.json"),
            withIntermediateDirectories: false)

        let error = #expect(throws: CodexOAuthCredentialsError.self) {
            try CodexOAuthCredentialsStore.loadOAuthTokens(env: ["CODEX_HOME": home.path])
        }
        guard case .unreadable = error else {
            Issue.record("Expected an unreadable auth path to remain distinguishable")
            return
        }
    }

    @Test
    func `malformed auth json maps to a safe decode error`() throws {
        let error = #expect(throws: CodexOAuthCredentialsError.self) {
            try CodexOAuthCredentialsStore.parse(data: Data("not-json".utf8))
        }
        guard case let .decodeFailed(message) = error else {
            Issue.record("Expected malformed JSON to map to decodeFailed")
            return
        }
        #expect(message == "Invalid JSON")
    }

    @Test
    func `open code oauth credentials preserve expiry and remain read only`() throws {
        let expiresAt = Date().addingTimeInterval(3600)
        let payload: [String: Any] = [
            "openai": [
                "type": "oauth",
                "access": "open-code-access",
                "refresh": "open-code-refresh",
                "expires": Int(expiresAt.timeIntervalSince1970 * 1000),
                "accountId": "open-code-account",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let credentials = try CodexOAuthCredentialsStore._parseOpenCodeForTesting(data: data)

        #expect(credentials.accessToken == "open-code-access")
        #expect(credentials.refreshToken == "open-code-refresh")
        #expect(credentials.accountId == "open-code-account")
        #expect(credentials.source == .openCode)
        #expect(credentials.expiresAt.map { abs($0.timeIntervalSince(expiresAt)) < 1 } == true)
        #expect(!credentials.needsRefresh)
        let error = #expect(throws: CodexOAuthCredentialsError.self) {
            try CodexOAuthCredentialsStore.save(credentials, env: ["CODEX_HOME": "/tmp/unused-codex-home"])
        }
        guard case .readOnlySource = error else {
            Issue.record("OpenCode credentials must never be persisted by CodexBar")
            return
        }
    }

    @Test
    func `expired open code oauth credentials are marked for refresh`() throws {
        let payload: [String: Any] = [
            "openai": [
                "type": "oauth",
                "access": "expired-access",
                "refresh": "expired-refresh",
                "expires": Int(Date().addingTimeInterval(-1).timeIntervalSince1970 * 1000),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let credentials = try CodexOAuthCredentialsStore._parseOpenCodeForTesting(data: data)

        #expect(credentials.source == .openCode)
        #expect(credentials.needsRefresh)
    }

    @Test
    func `expired read-only oauth credentials never invoke refresh`() async throws {
        let credentials = CodexOAuthCredentials(
            accessToken: "expired-access",
            refreshToken: "external-refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: nil,
            expiresAt: Date().addingTimeInterval(-1),
            source: .openCode)
        let recorder = RefreshInvocationRecorder()

        let error = await #expect(throws: CodexOAuthCredentialsError.self) {
            try await CodexOAuthFetchStrategy._prepareCredentialsForTesting(credentials) { _ in
                await recorder.record()
                return credentials
            }
        }
        guard case .readOnlySource = error else {
            Issue.record("Expired external credentials must fail before refresh")
            return
        }
        #expect(await recorder.count() == 0)
    }

    @Test
    func `expired read-only oauth credentials without a refresh token are rejected`() async throws {
        let credentials = CodexOAuthCredentials(
            accessToken: "expired-access",
            refreshToken: "",
            idToken: nil,
            accountId: nil,
            lastRefresh: nil,
            expiresAt: Date().addingTimeInterval(-1),
            source: .legacyCodexHome)

        let error = await #expect(throws: CodexOAuthCredentialsError.self) {
            try await CodexOAuthFetchStrategy._prepareCredentialsForTesting(credentials) { _ in
                Issue.record("An expired read-only credential must not reach a refresh closure")
                return credentials
            }
        }
        guard case .readOnlySource = error else {
            Issue.record("Expired external credentials without a refresh token must fail closed")
            return
        }
    }

    @Test
    func `expired read-only oauth credentials fail before the fetch sends a request`() async throws {
        let credentials = CodexOAuthCredentials(
            accessToken: "expired-access",
            refreshToken: "external-refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: nil,
            expiresAt: Date().addingTimeInterval(-1),
            source: .openCode)
        let requests = RefreshInvocationRecorder()
        let transport = ProviderHTTPTransportStub { _ in
            await requests.record()
            throw URLError(.badServerResponse)
        }

        let error = await #expect(throws: CodexOAuthCredentialsError.self) {
            try await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
                try await CodexOAuthFetchStrategy._fetchForTesting(
                    context: Self.context(),
                    credentials: credentials)
            }
        }
        guard case .readOnlySource = error else {
            Issue.record("The fetch path must reject expired external credentials before transport")
            return
        }
        #expect(await requests.count() == 0)
    }

    @Test
    func `valid read-only oauth credentials pass through without refresh`() async throws {
        let credentials = CodexOAuthCredentials(
            accessToken: "valid-access",
            refreshToken: "external-refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            source: .openCode)
        let recorder = RefreshInvocationRecorder()

        let resolved = try await CodexOAuthFetchStrategy._prepareCredentialsForTesting(credentials) { _ in
            await recorder.record()
            return credentials
        }

        #expect(resolved.accessToken == "valid-access")
        #expect(resolved.source == .openCode)
        #expect(await recorder.count() == 0)
    }

    @Test
    func `open code api credentials are not accepted as oauth`() throws {
        let payload: [String: Any] = [
            "openai": [
                "type": "api",
                "key": "open-code-api-key",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let error = #expect(throws: CodexOAuthCredentialsError.self) {
            try CodexOAuthCredentialsStore._parseOpenCodeForTesting(data: data)
        }
        guard case .missingTokens = error else {
            Issue.record("OpenCode API-key entries must not be treated as OAuth credentials")
            return
        }
    }

    private static func context() -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .oauth,
            includeCredits: false,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    @Test
    func `native codex home wins over external oauth sources`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-native-home-\(UUID().uuidString)", isDirectory: true)
        let dataHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-native-data-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: dataHome)
        }

        let nativeDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        let openCodeDirectory = dataHome.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: openCodeDirectory, withIntermediateDirectories: true)

        let native = """
        {
          "tokens": {
            "access_token": "native-access",
            "refresh_token": "native-refresh"
          }
        }
        """
        try Data(native.utf8).write(to: nativeDirectory.appendingPathComponent("auth.json"))
        let external: [String: Any] = [
            "openai": ["type": "oauth", "access": "external-access"],
        ]
        try JSONSerialization.data(withJSONObject: external)
            .write(to: openCodeDirectory.appendingPathComponent("auth.json"))

        let credentials = try CodexOAuthCredentialsStore._loadForUsageForTesting(
            env: ["XDG_DATA_HOME": dataHome.path],
            homeDirectory: home,
            allowExternalSources: true)

        #expect(credentials.source == .codexHome)
        #expect(credentials.accessToken == "native-access")
    }

    @Test
    func `legacy codex home wins before open code fallback`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-legacy-home-\(UUID().uuidString)", isDirectory: true)
        let dataHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-legacy-data-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: dataHome)
        }

        let legacyDirectory = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
        let openCodeDirectory = dataHome.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: openCodeDirectory, withIntermediateDirectories: true)

        let legacy = """
        {
          "tokens": {
            "access_token": "legacy-access",
            "refresh_token": "legacy-refresh"
          }
        }
        """
        try Data(legacy.utf8).write(to: legacyDirectory.appendingPathComponent("auth.json"))
        let external: [String: Any] = [
            "openai": ["type": "oauth", "access": "external-access"],
        ]
        try JSONSerialization.data(withJSONObject: external)
            .write(to: openCodeDirectory.appendingPathComponent("auth.json"))

        let credentials = try CodexOAuthCredentialsStore._loadForUsageForTesting(
            env: ["XDG_DATA_HOME": dataHome.path],
            homeDirectory: home,
            allowExternalSources: true)

        #expect(credentials.source == .legacyCodexHome)
        #expect(credentials.accessToken == "legacy-access")
    }

    @Test
    func `usage credential loading falls back to isolated open code data`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-fallback-home-\(UUID().uuidString)", isDirectory: true)
        let dataHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-fallback-data-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: dataHome)
        }
        let openCodeDirectory = dataHome.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: openCodeDirectory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "openai": [
                "type": "oauth",
                "access": "fallback-access",
                "refresh": "fallback-refresh",
                "expires": Int(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: openCodeDirectory.appendingPathComponent("auth.json"))

        let credentials = try CodexOAuthCredentialsStore._loadForUsageForTesting(
            env: ["XDG_DATA_HOME": dataHome.path],
            homeDirectory: home,
            allowExternalSources: true)

        #expect(credentials.source == .openCode)
        #expect(credentials.accessToken == "fallback-access")
    }

    @Test
    func `external OAuth fallback is disabled without explicit consent`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-consent-home-\(UUID().uuidString)", isDirectory: true)
        let dataHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-consent-data-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: dataHome)
        }
        let openCodeDirectory = dataHome.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: openCodeDirectory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "openai": ["type": "oauth", "access": "must-not-be-read"],
        ]
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: openCodeDirectory.appendingPathComponent("auth.json"))

        let error = #expect(throws: CodexOAuthCredentialsError.self) {
            try CodexOAuthCredentialsStore._loadForUsageForTesting(
                env: ["XDG_DATA_HOME": dataHome.path],
                homeDirectory: home)
        }
        guard case .notFound = error else {
            Issue.record("External OAuth files require explicit consent before they are read")
            return
        }
    }

    @Test
    func `explicit codex home does not borrow open code credentials`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-isolated-home-\(UUID().uuidString)", isDirectory: true)
        let dataHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-isolated-data-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: dataHome)
        }
        let openCodeDirectory = dataHome.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: openCodeDirectory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "openai": ["type": "oauth", "access": "should-not-be-used"],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: openCodeDirectory.appendingPathComponent("auth.json"))

        let error = #expect(throws: CodexOAuthCredentialsError.self) {
            try CodexOAuthCredentialsStore._loadForUsageForTesting(
                env: ["CODEX_HOME": home.path, "XDG_DATA_HOME": dataHome.path],
                homeDirectory: home)
        }
        guard case .notFound = error else {
            Issue.record("An explicit CODEX_HOME must not borrow an OpenCode credential")
            return
        }
    }
}

private actor RefreshInvocationRecorder {
    private var invocations = 0

    func record() {
        self.invocations += 1
    }

    func count() -> Int {
        self.invocations
    }
}
