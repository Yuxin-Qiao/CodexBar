import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
private final class ManualRefreshGate {
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
}

@MainActor
@Suite(.serialized)
struct StatusMenuProviderScopedRefreshTests {
    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuProviderScopedRefreshTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private func makeController(
        settings: SettingsStore,
        updater: UpdaterProviding = DisabledUpdaterController(),
        account: AccountInfo? = nil) -> StatusItemController
    {
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        if let account {
            store.accountInfoCache[.codex] = UsageStore.AccountInfoCacheEntry(
                account: account,
                configRevision: settings.configRevision,
                expiresAt: .distantFuture)
        }
        return StatusItemController(
            store: store,
            settings: settings,
            account: account ?? fetcher.loadAccountInfo(),
            updater: updater,
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
    }

    private func enableOnly(_ providers: Set<UsageProvider>, settings: SettingsStore) {
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: providers.contains(provider))
        }
    }

    @Test
    func `global manual refresh only marks active provider cards as refreshing`() {
        let settings = self.makeSettings()
        let controller = self.makeController(settings: settings)
        let monitor = controller.menuCardRefreshMonitor
        let fallback = MenuCardLiveSubtitle(text: "Idle", style: .info)

        monitor.beginManualRefresh(frozenModels: [:], provider: nil)
        defer { monitor.endManualRefresh() }

        controller.store.refreshingProviders.insert(.claude)
        #expect(monitor.isManualRefreshInFlight)
        #expect(!monitor.isManualRefreshInFlight(for: .codex))
        #expect(monitor.isManualRefreshInFlight(for: .claude))
        #expect(monitor.subtitle(for: .codex, fallback: fallback).style == .info)
        #expect(monitor.subtitle(for: .claude, fallback: fallback).style == .loading)

        controller.store.refreshingProviders.remove(.claude)
        #expect(!monitor.isManualRefreshInFlight(for: .claude))
        #expect(monitor.subtitle(for: .claude, fallback: fallback).style == .info)
    }

    @Test
    func `completed provider cards stop refreshing while another provider is still running`() async {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = false
        settings.openAIWebAccessEnabled = false
        settings.codexCookieSource = .off
        self.enableOnly([.claude, .codex], settings: settings)
        let controller = self.makeController(settings: settings)
        let claudeStarted = ManualRefreshGate()
        let releaseClaude = ManualRefreshGate()
        let monitor = controller.menuCardRefreshMonitor
        let fallback = MenuCardLiveSubtitle(text: "Idle", style: .info)

        controller.store._test_providerRefreshOverride = { provider in
            guard provider == .claude else { return }
            claudeStarted.resume()
            await releaseClaude.wait()
        }
        defer { controller.store._test_providerRefreshOverride = nil }

        controller.refreshNow()
        await claudeStarted.wait()
        for _ in 0..<20 where controller.store.refreshingProviders != [.claude] {
            await Task.yield()
        }

        #expect(controller.store.refreshingProviders == [.claude])
        #expect(!monitor.isManualRefreshInFlight(for: .codex))
        #expect(monitor.isManualRefreshInFlight(for: .claude))
        #expect(monitor.subtitle(for: .codex, fallback: fallback).style == .info)
        #expect(monitor.subtitle(for: .claude, fallback: fallback).style == .loading)

        releaseClaude.resume()
        await controller.manualRefreshTasks[.global]?.value
    }

    @Test
    func `token-cost tail does not keep completed provider card refreshing`() async {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        settings.openAIWebAccessEnabled = false
        settings.codexCookieSource = .off
        self.enableOnly([.codex], settings: settings)
        let controller = self.makeController(settings: settings)
        let tokenRefreshStarted = ManualRefreshGate()
        let releaseTokenRefresh = ManualRefreshGate()
        let monitor = controller.menuCardRefreshMonitor
        let fallback = MenuCardLiveSubtitle(text: "Idle", style: .info)

        controller.store._test_providerRefreshOverride = { _ in }
        controller.store._test_tokenUsageRefreshOverride = { _, _ in
            tokenRefreshStarted.resume()
            await releaseTokenRefresh.wait()
        }
        defer {
            controller.store._test_providerRefreshOverride = nil
            controller.store._test_tokenUsageRefreshOverride = nil
        }

        controller.refreshNow()
        await tokenRefreshStarted.wait()

        #expect(controller.store.isRefreshing)
        #expect(controller.store.refreshingProviders.isEmpty)
        #expect(monitor.isManualRefreshInFlight)
        #expect(!monitor.isManualRefreshInFlight(for: .codex))
        #expect(monitor.subtitle(for: .codex, fallback: fallback).style == .info)

        releaseTokenRefresh.resume()
        await controller.manualRefreshTasks[.global]?.value
        #expect(!monitor.isManualRefreshInFlight)
    }
}
