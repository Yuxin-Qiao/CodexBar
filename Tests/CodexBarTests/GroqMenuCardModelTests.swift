import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension StatusMenuTests {
    @Test
    func `groq cost data is available in both generic and inline dashboards`() throws {
        StatusItemController.menuCardRenderingEnabled = true
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        defer { self.disableMenuCardsForTesting() }
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.selectedMenuProvider = .groq
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .costSubmenu

        let metadata = try #require(ProviderRegistry.shared.metadata[.groq])
        settings.setProviderEnabled(provider: .groq, metadata: metadata, enabled: true)

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let usage = GroqConsoleUsageSnapshot(
            daily: [
                GroqConsoleUsageSnapshot.DailyBucket(
                    day: "2023-11-14",
                    startTime: now.addingTimeInterval(-86400),
                    endTime: now,
                    costUSD: 1.5,
                    requests: 10,
                    inputTokens: 100,
                    cachedInputTokens: 0,
                    outputTokens: 50,
                    totalTokens: 150,
                    models: []),
            ],
            updatedAt: now)
        store._setSnapshotForTesting(usage.toUsageSnapshot(), provider: .groq)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        // Groq exposes structured token and cost history, so it participates in the descriptor-
        // driven generic Cost section while retaining its richer provider-specific dashboard.
        let model = try #require(controller.menuCardModel(for: .groq))
        #expect(model.tokenUsage?.sessionLine == "Today: $0.00 · 0 tokens")
        #expect(model.tokenUsage?.monthLine == "Last 30 days: $1.50 · 150 tokens")
        #expect(model.inlineUsageDashboard != nil)
    }
}
