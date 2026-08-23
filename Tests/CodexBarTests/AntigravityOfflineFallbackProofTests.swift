import Foundation
import Testing
@testable import CodexBarCore

struct AntigravityOfflineFallbackProofTests {
    @Test
    func `counts db in app-data directory`() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // app_data_dir = ~/.gemini/antigravity  (as launched with --app_data_dir)
        let appData = AntigravityOfflineStore.appDataDirectory(home: tmp, env: [:])
        try FileManager.default.createDirectory(at: appData, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: appData.appendingPathComponent("a.db").path, contents: Data())
        FileManager.default.createFile(atPath: appData.appendingPathComponent("b.db").path, contents: Data())
        #expect(AntigravityOfflineStore.countConversations(home: tmp) == 2)
        #expect(AntigravityOfflineStore.hasOfflineData(home: tmp))
    }

    @Test
    func `counts db in app-data conversations subdirectory`() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let appDataConv = AntigravityOfflineStore.appDataDirectory(home: tmp, env: [:])
            .appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: appDataConv, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: appDataConv.appendingPathComponent("c.db").path, contents: Data())
        #expect(AntigravityOfflineStore.countConversations(home: tmp) == 1)
    }

    @Test
    func `offline snapshot does not carry selected OAuth email`() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let conv = AntigravityOfflineStore.conversationsDirectory(home: tmp, env: [:])
        try FileManager.default.createDirectory(at: conv, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: conv.appendingPathComponent("x.db").path, contents: Data())
        // Simulate selected OAuth account
        let credentials = AntigravityOAuthCredentials(
            accessToken: "ya29.fake",
            refreshToken: "1//fake",
            expiryDate: Date().addingTimeInterval(3600),
            email: "selected@example.com")
        guard let tokenValue = try? AntigravityOAuthCredentialsStore.tokenAccountValue(for: credentials) else {
            Issue.record("failed to encode credentials"); return
        }
        let context = ProviderFetchContext(
            provider: .antigravity,
            sourceMode: .auto,
            env: ["HOME": tmp.path, AntigravityOAuthCredentialsStore.environmentCredentialsKey: tokenValue],
            selectedTokenAccountID: "acc-1",
            tokenAccountTokenUpdater: nil,
            settings: ProviderSettingsStore(),
            now: Date())
        let strategy = AntigravityOfflineFetchStrategy()
        let result = try await strategy.fetch(context)
        #expect(result.usage.identity?.accountEmail == nil)
        #expect(result.usage.extraRateWindows?.first?.title == "Offline · 1 conversation")
        #expect(result.sourceLabel == "offline")
    }

    @Test
    func `oauth shouldFallback when offline data exists`() async {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let conv = AntigravityOfflineStore.conversationsDirectory(home: tmp, env: [:])
        try? FileManager.default.createDirectory(at: conv, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: conv.appendingPathComponent("a.db").path, contents: Data())
        let ctxWithData = ProviderFetchContext(
            provider: .antigravity,
            sourceMode: .auto,
            env: ["HOME": tmp.path],
            selectedTokenAccountID: nil,
            tokenAccountTokenUpdater: nil,
            settings: ProviderSettingsStore(),
            now: Date())
        let ctxEmpty = ProviderFetchContext(
            provider: .antigravity,
            sourceMode: .auto,
            env: ["HOME": "/tmp/empty-\(UUID().uuidString)"],
            selectedTokenAccountID: nil,
            tokenAccountTokenUpdater: nil,
            settings: ProviderSettingsStore(),
            now: Date())
        let oauth = AntigravityOAuthFetchStrategy()
        let shouldFallbackWithData = await oauth.shouldFallback(
            on: ProviderFetchError.noAvailableStrategy(.antigravity),
            context: ctxWithData)
        let shouldFallbackEmpty = await oauth.shouldFallback(
            on: ProviderFetchError.noAvailableStrategy(.antigravity),
            context: ctxEmpty)
        #expect(shouldFallbackWithData == true)
        #expect(shouldFallbackEmpty == false)
    }
}
