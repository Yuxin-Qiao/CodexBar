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
    func `expired open code oauth credentials request a refresh`() throws {
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
            homeDirectory: home)

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
            homeDirectory: home)

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
            homeDirectory: home)

        #expect(credentials.source == .openCode)
        #expect(credentials.accessToken == "fallback-access")
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
