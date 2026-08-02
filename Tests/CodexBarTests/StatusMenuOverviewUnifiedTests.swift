import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuOverviewUnifiedTests {
    @Test
    func `unified card appears and lists every enabled provider`() throws {
        let settings = self.makeSettings()
        settings.mergeIcons = true
        settings.costUsageEnabled = true
        settings.mergedMenuLastSelectedWasOverview = true
        self.enableOnly([.codex, .claude, .cursor, .opencode], settings: settings)

        let store = self.makeStore(settings: settings)
        let now = Date()
        for provider in [.codex, .claude, .cursor, .opencode] as [UsageProvider] {
            store._setSnapshotForTesting(self.usageSnapshot(used: 22, now: now), provider: provider)
        }
        store._setTokenSnapshotForTesting(
            self.tokenSnapshot(tokens: 1_000_000, cost: 1.5),
            provider: .codex)
        store._setTokenSnapshotForTesting(
            self.tokenSnapshot(tokens: 2_000_000, cost: 2.5),
            provider: .claude)

        let controller = self.makeController(settings: settings, store: store)
        let menu = try #require(controller.makeMenu() as? StatusItemMenu)
        controller.mergedMenu = menu
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        let card = try #require(menu.items.first {
            $0.representedObject as? String == StatusItemController.overviewUnifiedRowIdentifier
        })
        let submenu = try #require(card.submenu)
        let providerItems = submenu.items.filter {
            ($0.representedObject as? String)?.hasPrefix(StatusItemController.overviewRowIdentifierPrefix) == true
        }
        #expect(providerItems.map(\.title).count == 4)
        #expect(submenu.items.first?.title == L("tab_usage_spend"))

        let model = try #require(controller.makeOverviewUnifiedModel(
            enabledProviders: [.codex, .claude, .cursor, .opencode]))
        #expect(model.quotaRows.count == 4)
        #expect(model.totals?.totalTokens == 3_000_000)
    }

    @Test
    func `unified card hidden when no provider has quota data`() throws {
        let settings = self.makeSettings()
        settings.mergeIcons = true
        settings.costUsageEnabled = true
        settings.mergedMenuLastSelectedWasOverview = true
        self.enableOnly([.codex, .claude], settings: settings)

        let store = self.makeStore(settings: settings)
        let controller = self.makeController(settings: settings, store: store)
        let menu = try #require(controller.makeMenu() as? StatusItemMenu)
        controller.mergedMenu = menu
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        #expect(controller.makeOverviewUnifiedModel(enabledProviders: [.codex, .claude]) == nil)
        #expect(menu.items.contains {
            $0.representedObject as? String == StatusItemController.overviewUnifiedRowIdentifier
        } == false)
    }

    @Test
    func `submenu contribution click switches to that provider`() throws {
        let settings = self.makeSettings()
        settings.mergeIcons = true
        settings.costUsageEnabled = true
        settings.mergedMenuLastSelectedWasOverview = true
        self.enableOnly([.codex, .claude], settings: settings)

        let store = self.makeStore(settings: settings)
        let now = Date()
        store._setSnapshotForTesting(self.usageSnapshot(used: 22, now: now), provider: .codex)
        store._setSnapshotForTesting(self.usageSnapshot(used: 55, now: now), provider: .claude)

        let controller = self.makeController(settings: settings, store: store)
        let menu = try #require(controller.makeMenu() as? StatusItemMenu)
        controller.mergedMenu = menu
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        let card = try #require(menu.items.first {
            $0.representedObject as? String == StatusItemController.overviewUnifiedRowIdentifier
        })
        let submenu = try #require(card.submenu)
        let claudeItem = try #require(submenu.items.first {
            $0.representedObject as? String ==
                "\(StatusItemController.overviewRowIdentifierPrefix)claude"
        })

        controller.selectOverviewContributionProvider(claudeItem)
        #expect(settings.mergedMenuLastSelectedWasOverview == false)
        #expect(settings.selectedMenuProvider == .claude)
    }

    @Test
    func `unified card refreshes when provider usage changes`() throws {
        let settings = self.makeSettings()
        settings.mergeIcons = true
        settings.costUsageEnabled = true
        settings.mergedMenuLastSelectedWasOverview = true
        self.enableOnly([.codex, .claude], settings: settings)

        let store = self.makeStore(settings: settings)
        let now = Date()
        store._setSnapshotForTesting(self.usageSnapshot(used: 22, now: now), provider: .codex)
        store._setSnapshotForTesting(self.usageSnapshot(used: 55, now: now), provider: .claude)

        let controller = self.makeController(settings: settings, store: store)
        let menu = try #require(controller.makeMenu() as? StatusItemMenu)
        controller.mergedMenu = menu
        controller.menuWillOpen(menu)

        store._setSnapshotForTesting(self.usageSnapshot(used: 88, now: now), provider: .claude)
        controller.menuDidClose(menu)
        let refreshedMenu = try #require(controller.makeMenu() as? StatusItemMenu)
        controller.mergedMenu = refreshedMenu
        controller.menuWillOpen(refreshedMenu)
        defer { controller.menuDidClose(refreshedMenu) }

        let card = try #require(refreshedMenu.items.first {
            $0.representedObject as? String == StatusItemController.overviewUnifiedRowIdentifier
        })
        let submenu = try #require(card.submenu)
        let claudeItem = try #require(submenu.items.first {
            $0.representedObject as? String ==
                "\(StatusItemController.overviewRowIdentifierPrefix)claude"
        })
        #expect(claudeItem.title.contains("12%"))
    }

    @Test
    func `error provider appears exactly once as an error chip`() throws {
        let settings = self.makeSettings()
        settings.mergeIcons = true
        settings.costUsageEnabled = false
        self.enableOnly([.codex, .claude, .cursor], settings: settings)

        let store = self.makeStore(settings: settings)
        let now = Date()
        store._setSnapshotForTesting(self.usageSnapshot(used: 22, now: now), provider: .codex)
        store._setSnapshotForTesting(self.usageSnapshot(used: 88, now: now), provider: .claude)
        store._setErrorForTesting("Needs sign-in", provider: .cursor)

        let controller = self.makeController(settings: settings, store: store)
        let model = try #require(controller.makeOverviewUnifiedModel(
            enabledProviders: [.codex, .claude, .cursor]))

        let cursorRows = model.quotaRows.filter { $0.provider == .cursor }
        #expect(cursorRows.count == 1)
        let cursorRow = try #require(cursorRows.first)
        #expect(cursorRow.hasError)
        #expect(cursorRow.errorText?.contains("Needs sign-in") == true)
        #expect(cursorRow.remainingPercent == nil)
        // Errors render inside the chip grid; no separate attention lines exist.
        #expect(model.resetLines.allSatisfy { !$0.contains("Cursor") })
    }

    @Test
    func `reset lines list at most two providers with reset info`() throws {
        let settings = self.makeSettings()
        settings.mergeIcons = true
        settings.costUsageEnabled = false
        self.enableOnly([.codex, .claude, .cursor], settings: settings)

        let store = self.makeStore(settings: settings)
        let now = Date()
        store._setSnapshotForTesting(self.usageSnapshot(used: 22, now: now), provider: .codex)
        store._setSnapshotForTesting(self.usageSnapshot(used: 55, now: now), provider: .claude)
        store._setSnapshotForTesting(self.usageSnapshot(used: 88, now: now), provider: .cursor)

        let controller = self.makeController(settings: settings, store: store)
        let model = try #require(controller.makeOverviewUnifiedModel(
            enabledProviders: [.codex, .claude, .cursor]))

        #expect(model.resetLines.count == 2)
        #expect(model.resetLines.first?.contains("Codex") == true)
        #expect(model.resetLines.last?.contains("Claude") == true)
    }

    @Test
    func `reset lines empty when no provider reports reset info`() throws {
        let settings = self.makeSettings()
        settings.mergeIcons = true
        settings.costUsageEnabled = false
        self.enableOnly([.codex, .claude], settings: settings)

        let store = self.makeStore(settings: settings)
        let now = Date()
        store._setSnapshotForTesting(self.usageSnapshotWithoutReset(used: 22, now: now), provider: .codex)
        store._setSnapshotForTesting(self.usageSnapshotWithoutReset(used: 55, now: now), provider: .claude)

        let controller = self.makeController(settings: settings, store: store)
        let model = try #require(controller.makeOverviewUnifiedModel(
            enabledProviders: [.codex, .claude]))

        #expect(model.resetLines.isEmpty)
        #expect(model.quotaRows.count == 2)
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuOverviewUnifiedTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private func makeStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
    }

    private func makeController(
        settings: SettingsStore,
        store: UsageStore) -> StatusItemController
    {
        StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
    }

    private func enableOnly(_ providers: Set<UsageProvider>, settings: SettingsStore) {
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: providers.contains(provider))
        }
    }

    private func usageSnapshot(used: Double, now: Date) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: used,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(1800),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now)
    }

    private func usageSnapshotWithoutReset(used: Double, now: Date) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: used,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now)
    }

    private func tokenSnapshot(tokens: Int, cost: Double) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: tokens,
            last30DaysCostUSD: cost,
            currencyCode: "USD",
            historyDays: 30,
            historyCoverageIsEstablished: true,
            daily: [],
            updatedAt: Date())
    }
}
