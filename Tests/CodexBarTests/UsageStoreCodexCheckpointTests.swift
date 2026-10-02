import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct UsageStoreCodexCheckpointTests {
    @Test
    func `incomplete growth publishes today while retaining established history`() throws {
        let store = try Self.makeStore()
        let now = Date()
        let today = CostUsageLocalDay.key(from: now, calendar: store.settings.costUsageBucketCalendar)
        let older = CostUsageLocalDay.key(
            from: now.addingTimeInterval(-86400), calendar: store.settings.costUsageBucketCalendar)
        store.publishTokenSnapshot(Self.snapshot(days: [(older, 50), (today, 100)], now: now), for: .codex)
        store.publishTokenSnapshot(Self.snapshot(days: [(today, 120)], now: now, complete: false), for: .codex)
        let result = try #require(store.tokenSnapshot(for: .codex))
        #expect(result.sessionTokens == 120)
        #expect(result.last30DaysTokens == 170)
        #expect(result.daily.map(\.date) == [older, today])
        #expect(result.historyScanIsPartial)
        #expect(!result.historyIsFullyScanned)
        store.publishTokenSnapshot(Self.snapshot(days: [(today, 110)], now: now, complete: false), for: .codex)
        #expect(store.tokenSnapshot(for: .codex)?.sessionTokens == 120)
        store.publishTokenSnapshot(Self.snapshot(days: [(older, 40), (today, 90)], now: now), for: .codex)
        #expect(store.tokenSnapshot(for: .codex)?.last30DaysTokens == 130)
        #expect(store.tokenSnapshot(for: .codex)?.historyIsFullyScanned == true)
    }

    @Test
    func `checkpoint cannot cross settings or accounting scopes`() throws {
        let store = try Self.makeStore()
        let now = Date()
        let day = CostUsageLocalDay.key(from: now, calendar: store.settings.costUsageBucketCalendar)
        let initial = Self.snapshot(days: [(day, 100)], now: now)
        store.publishTokenSnapshot(initial, for: .codex, accounting: .includesPi(scope: "one", native: initial))
        store.publishTokenSnapshot(
            Self.snapshot(days: [(day, 120)], now: now, complete: false),
            for: .codex,
            accounting: .includesPi(scope: "two", native: initial))
        #expect(store.tokenSnapshot(for: .codex)?.sessionTokens == 100)
        store.settings.costUsageHistoryDays = 7
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex) == nil)
    }

    @Test
    func `inclusive checkpoint preserves native ownership and accepts later growth`() throws {
        let store = try Self.makeStore()
        let now = Date()
        let day = CostUsageLocalDay.key(from: now, calendar: store.settings.costUsageBucketCalendar)
        let native = Self.snapshot(days: [(day, 100)], now: now)
        store.publishTokenSnapshot(
            Self.snapshot(days: [(day, 150)], now: now),
            for: .codex,
            accounting: .includesPi(scope: "fixture", native: native))
        let nextNative = Self.snapshot(days: [(day, 120)], now: now, complete: false)
        store.publishTokenSnapshot(
            Self.snapshot(days: [(day, 170)], now: now, complete: false),
            for: .codex,
            accounting: .includesPi(scope: "fixture", native: nextNative))
        let publication = try #require(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex))
        #expect(publication.snapshot?.sessionTokens == 170)
        guard case let .includesPi(_, retainedNative)? = publication.accounting else {
            Issue.record("Native accounting was lost")
            return
        }
        #expect(retainedNative.sessionTokens == 120)
        store.publishTokenSnapshot(
            Self.snapshot(days: [(day, 180)], now: now, complete: false),
            for: .codex,
            accounting: .includesPi(scope: "fixture", native: nextNative))
        #expect(store.tokenSnapshot(for: .codex)?.sessionTokens == 180)
        let completedNative = Self.snapshot(days: [(day, 90)], now: now)
        store.publishTokenSnapshot(
            Self.snapshot(days: [(day, 190)], now: now, complete: false),
            for: .codex,
            accounting: .includesPi(scope: "fixture", native: completedNative))
        let reconciled = try #require(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex))
        guard case let .includesPi(_, reconciledNative)? = reconciled.accounting else {
            Issue.record("Completed native accounting was lost")
            return
        }
        #expect(reconciledNative.sessionTokens == 90)
        #expect(reconciledNative.historyIsFullyScanned)
    }

    private static func makeStore() throws -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "UsageStoreCodexCheckpointTests",
            userDefaults: InMemoryUserDefaults(),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { false }))
        settings.costUsageEnabled = true
        settings.costUsageHistoryDays = 30
        try settings.setProviderEnabled(
            provider: .codex,
            metadata: #require(ProviderRegistry.shared.metadata[.codex]),
            enabled: true)
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }

    private static func snapshot(days: [(String, Int)], now: Date, complete: Bool = true) -> CostUsageTokenSnapshot {
        let entries = days.map { day, tokens in
            CostUsageDailyReport.Entry(
                date: day,
                inputTokens: tokens,
                outputTokens: 0,
                totalTokens: tokens,
                costUSD: Double(tokens) / 100,
                modelsUsed: nil,
                modelBreakdowns: nil)
        }
        return CostUsageTokenSnapshot(
            sessionTokens: days.last?.1,
            sessionCostUSD: days.last.map { Double($0.1) / 100 },
            last30DaysTokens: days.reduce(0) { $0 + $1.1 },
            last30DaysCostUSD: Double(days.reduce(0) { $0 + $1.1 }) / 100,
            historyCoverageIsEstablished: complete,
            daily: entries,
            updatedAt: now)
    }
}
