import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
private final class ScopedRefreshGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if self.isOpen {
            self.isOpen = false
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        if let continuation = self.continuation {
            continuation.resume()
            self.continuation = nil
        } else {
            self.isOpen = true
        }
    }

    func waitUntilSignaled(timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !self.isOpen {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        self.isOpen = false
        return true
    }
}

@MainActor
@Suite(.serialized)
struct StatusMenuScopedCodexRefreshTests {
    @Test
    func `scoped refresh publishes quota before dashboard enrichment completes`() async {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = false
        settings.openAIWebAccessEnabled = true
        settings.codexCookieSource = .manual
        settings.codexCookieHeader = "session=fixture"
        self.enableOnlyCodex(settings)

        let account = AccountInfo(email: "test@example.com", plan: "pro")
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store.accountInfoCache[.codex] = UsageStore.AccountInfoCacheEntry(
            account: account,
            configRevision: settings.configRevision,
            expiresAt: .distantFuture)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: account,
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        let dashboardStarted = ScopedRefreshGate()
        let releaseDashboard = ScopedRefreshGate()

        store._test_providerRefreshOverride = { provider in
            #expect(provider == .codex)
        }
        store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
        }
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            dashboardStarted.resume()
            await releaseDashboard.wait()
            return OpenAIDashboardSnapshot(
                signedInEmail: account.email,
                codeReviewRemainingPercent: 95,
                creditEvents: [],
                dailyBreakdown: [],
                usageBreakdown: [],
                creditsPurchaseURL: nil,
                creditsRemaining: 25,
                accountPlan: "Pro",
                updatedAt: Date())
        }
        defer {
            releaseDashboard.resume()
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_openAIDashboardLoaderOverride = nil
        }

        controller.menuCardRefreshMonitor.beginManualRefresh(frozenModels: [:], provider: .codex)
        let refreshTask = Task { @MainActor in
            await controller.performStoreRefresh(
                for: .codex,
                refreshOpenMenusWhenComplete: false,
                interaction: .userInitiated)
        }
        #expect(await dashboardStarted.waitUntilSignaled())
        #expect(!controller.menuCardRefreshMonitor.isManualRefreshInFlight(for: .codex))

        releaseDashboard.resume()
        await refreshTask.value
    }

    @Test
    func `scoped refresh reconciles usage after dashboard login expires`() async {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.openAIWebAccessEnabled = true
        settings.codexCookieSource = .auto
        self.enableOnlyCodex(settings)

        let account = AccountInfo(email: "test@example.com", plan: "pro")
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store.accountInfoCache[.codex] = UsageStore.AccountInfoCacheEntry(
            account: account,
            configRevision: settings.configRevision,
            expiresAt: .distantFuture)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: account,
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)

        var providerRefreshes = 0
        store._test_providerRefreshOverride = { provider in
            #expect(provider == .codex)
            providerRefreshes += 1
        }
        store._test_tokenUsageRefreshOverride = { _, _ in }
        store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
        }
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            throw OpenAIDashboardFetcher.FetchError.loginRequired
        }
        store._test_openAIDashboardCookieImportOverride = { targetEmail, _, _, _, _ in
            OpenAIDashboardBrowserCookieImporter.ImportResult(
                sourceLabel: "Chrome",
                cookieCount: 2,
                signedInEmail: targetEmail,
                matchesCodexEmail: true)
        }

        await controller.performStoreRefresh(
            for: .codex,
            refreshOpenMenusWhenComplete: false,
            interaction: .userInitiated)

        #expect(store.openAIDashboardRequiresLogin)
        #expect(providerRefreshes == 2)
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuScopedCodexRefreshTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private func enableOnlyCodex(_ settings: SettingsStore) {
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
    }
}
