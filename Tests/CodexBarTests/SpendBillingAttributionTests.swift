import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendBillingAttributionTests {
    @Test
    func `subscription rows follow the vendor that owns the quota`() throws {
        let inputs = [
            SpendDashboardModel.ProviderInput(
                id: "cursor",
                provider: .cursor,
                displayName: "Cursor",
                snapshot: Self.snapshot([
                    Self.entry(model: "default", cost: 50, tokens: 500),
                    Self.entry(model: "claude-sonnet-4-6", cost: 100, tokens: 1000),
                    Self.entry(model: "k3", cost: 25, tokens: 250, billingProviderID: "kimi"),
                ])),
            SpendDashboardModel.ProviderInput(
                id: "antigravity",
                provider: .antigravity,
                displayName: "Antigravity",
                snapshot: Self.snapshot([
                    Self.entry(model: "gemini-3.1-pro", cost: 80, tokens: 800),
                    Self.entry(model: "claude-opus-4-6", cost: 20, tokens: 200),
                ])),
            SpendDashboardModel.ProviderInput(
                id: "codex",
                provider: .codex,
                displayName: "Codex",
                snapshot: Self.snapshot([
                    Self.entry(model: "gpt-5.5", cost: 300, tokens: 3000),
                    Self.entry(model: "MiniMax-M3", cost: 70, tokens: 700, billingProviderID: "minimax"),
                ])),
            SpendDashboardModel.ProviderInput(
                id: "claude",
                provider: .claude,
                displayName: "Claude Code",
                snapshot: Self.snapshot([
                    Self.entry(model: "deepseek-v4-pro", cost: 40, tokens: 400, billingProviderID: "deepseek"),
                    Self.entry(model: "kimi-for-coding", cost: 20, tokens: 200, billingProviderID: "moonshot"),
                    Self.entry(model: "claude-sonnet-4-6", cost: 5, tokens: 50),
                ])),
            SpendDashboardModel.ProviderInput(
                id: "kimi-native",
                provider: .kimi,
                displayName: "Kimi Code CLI",
                snapshot: Self.snapshot([
                    Self.entry(model: "kimi-code/k3", cost: 10, tokens: 100),
                ])),
            SpendDashboardModel.ProviderInput(
                id: "minimax-native",
                provider: .minimax,
                displayName: "MiniMax Code",
                snapshot: Self.snapshot([
                    Self.entry(model: "MiniMax-M3", cost: 0.23, tokens: 17),
                ])),
        ]

        let group = try #require(SpendDashboardModel.build(
            inputs: inputs,
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.providers.map(\.provider) == [
            .codex,
            .cursor,
            .antigravity,
            .minimax,
            .deepseek,
            .kimi,
            .moonshot,
            .claude,
        ])
        #expect(group.providers.map(\.id) == [
            "codex",
            "cursor",
            "antigravity",
            "minimax-native",
            "billing:deepseek:claude",
            "kimi-native",
            "billing:moonshot:claude",
            "claude",
        ])
        #expect(group.providers.map(\.totalCost) == [300, 150, 100, 70.23, 40, 35, 20, 5])
        #expect(group.providers.map(\.displayName) == [
            "Codex",
            "Cursor",
            "Antigravity",
            "MiniMax",
            "DeepSeek",
            "Kimi",
            "Moonshot / Kimi API",
            "Claude",
        ])
        #expect(group.providers.first(where: { $0.provider == .kimi })?.totalTokens == 350)
        #expect(group.providers.first(where: { $0.provider == .moonshot })?.totalTokens == 200)
        #expect(group.providers.first(where: { $0.provider == .minimax })?.totalTokens == 717)
    }

    @Test
    func `model labels alone never change the billing owner`() {
        #expect(SpendBillingAttribution.billingVendor(forModel: "default", defaultProvider: .cursor) == .cursor)
        #expect(SpendBillingAttribution.billingVendor(
            forModel: "claude-sonnet-4-6",
            defaultProvider: .cursor) == .cursor)
        #expect(SpendBillingAttribution.billingVendor(forModel: "gpt-5.6", defaultProvider: .cursor) == .cursor)
        #expect(SpendBillingAttribution.billingVendor(forModel: "k3", defaultProvider: .cursor) == .cursor)
        #expect(SpendBillingAttribution.billingVendor(
            forModel: "kimi-for-coding",
            defaultProvider: .cursor) == .cursor)
        #expect(SpendBillingAttribution.billingVendor(
            forModel: "MiniMax-M3",
            defaultProvider: .cursor) == .cursor)
        #expect(SpendBillingAttribution.billingVendor(
            forModel: "deepseek-v4",
            defaultProvider: .cursor) == .cursor)
    }

    @Test
    func `moonshotai billing aliases map to the Moonshot API vendor`() throws {
        let inputs = [
            SpendDashboardModel.ProviderInput(
                id: "claude",
                provider: .claude,
                displayName: "Claude Code",
                snapshot: Self.snapshot([
                    Self.entry(model: "kimi-k3", cost: 12, tokens: 120, billingProviderID: "moonshotai"),
                    Self.entry(model: "kimi-k2.6", cost: 3, tokens: 30, billingProviderID: "moonshotai-cn"),
                ])),
        ]

        let group = try #require(SpendDashboardModel.build(
            inputs: inputs,
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        let moonshot = try #require(group.providers.first { $0.provider == .moonshot })
        #expect(moonshot.id == "billing:moonshot:claude")
        #expect(moonshot.displayName == "Moonshot / Kimi API")
        #expect(moonshot.totalTokens == 150)
        #expect(moonshot.totalCost == 15)
        #expect(group.providers.contains { $0.provider == .kimi } == false)
    }

    @Test
    func `only explicit model namespaces become billing evidence`() {
        #expect(CostUsageBillingProvider.providerID(fromNamespacedModel: "MiniMax-M3") == nil)
        #expect(CostUsageBillingProvider.providerID(fromNamespacedModel: "minimax/MiniMax-M3") == "minimax")
        #expect(CostUsageBillingProvider.providerID(fromNamespacedModel: "qwen/qwen3-coder") == "qwencloud")
        #expect(CostUsageBillingProvider.providerID(fromNamespacedModel: "moonshot/kimi-k2") == "moonshot")
        #expect(CostUsageBillingProvider.providerID(
            fromNamespacedModel: "gateway/team/moonshot/kimi-k2") == "moonshot")
        #expect(CostUsageBillingProvider.providerID(
            fromNamespacedModel: "openrouter/anthropic/claude-sonnet-4") == "claude")
        #expect(CostUsageBillingProvider.providerID(fromNamespacedModel: "gateway/team/model") == nil)
        #expect(CostUsageBillingProvider.providerID(fromNamespacedModel: "/unowned") == nil)
    }

    @Test
    func `bundled and official tools never leak models to another subscription`() {
        #expect(SpendBillingAttribution.billingVendor(
            forModel: "claude-opus-4-6",
            defaultProvider: .antigravity) == .antigravity)
        #expect(SpendBillingAttribution.billingVendor(
            forModel: "gemini-3.6-flash",
            defaultProvider: .antigravity) == .antigravity)
        #expect(SpendBillingAttribution.billingVendor(
            forModel: "k3",
            defaultProvider: .kimi) == .kimi)
        #expect(SpendBillingAttribution.billingVendor(
            forModel: "MiniMax-M3",
            defaultProvider: .minimax) == .minimax)
    }

    @Test
    func `live quota snapshot does not erase complete MiniMax local history`() throws {
        let liveQuota = CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            currencyCode: "USD",
            historyDays: 30,
            historyCoverageIsEstablished: false,
            daily: [],
            updatedAt: Self.now)
        let localHistory = Self.snapshot([
            Self.entry(model: "minimax/MiniMax-M3", cost: 0.23, tokens: 1_738_342),
        ])
        let model = SpendDashboardModel.build(
            inputs: [
                SpendDashboardModel.ProviderInput(
                    id: "minimax",
                    provider: .minimax,
                    displayName: "MiniMax",
                    subscriptionName: "Token Plan Plus",
                    snapshot: liveQuota),
                SpendDashboardModel.ProviderInput(
                    id: "minimax:local",
                    provider: .minimax,
                    displayName: "MiniMax",
                    snapshot: localHistory),
            ],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)

        let row = try #require(model.groups.first?.providers.first)
        #expect(row.id == "minimax:local")
        #expect(row.displayName == "MiniMax")
        #expect(row.subscriptionName == "Token Plan Plus")
        #expect(row.totalTokens == 1_738_342)
        #expect(abs((row.totalCost ?? 0) - 0.23) < 0.000_001)
    }

    @Test
    func `inactive recent MiniMax window is zero while cumulative keeps historical spend`() throws {
        let now = Date(timeIntervalSince1970: 1_785_427_200) // 2026-07-29 00:00:00 UTC
        let entry = CostUsageDailyReport.Entry(
            date: "2026-07-12",
            inputTokens: 1_000_000,
            outputTokens: 738_342,
            totalTokens: 1_738_342,
            costUSD: 0.23,
            modelsUsed: ["minimax/MiniMax-M3"],
            modelBreakdowns: [CostUsageDailyReport.ModelBreakdown(
                modelName: "minimax/MiniMax-M3",
                costUSD: 0.23,
                totalTokens: 1_738_342,
                inputTokens: 1_000_000,
                outputTokens: 738_342)])
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 1_738_342,
            last30DaysCostUSD: 0.23,
            currencyCode: "USD",
            historyDays: 365,
            historyCoverageIsEstablished: true,
            daily: [entry],
            updatedAt: now)
        let input = SpendDashboardModel.ProviderInput(
            provider: .minimax,
            displayName: "MiniMax",
            subscriptionName: "Token Plan Plus",
            snapshot: snapshot)

        let recent = try #require(SpendDashboardModel.build(
            inputs: [input],
            requestedDays: 7,
            now: now,
            calendar: Self.calendar).groups.first?.providers.first)
        let cumulative = try #require(SpendDashboardModel.build(
            inputs: [input],
            requestedDays: 365,
            now: now,
            calendar: Self.calendar).groups.first?.providers.first)

        #expect(recent.totalTokens == 0)
        #expect(recent.totalCost == 0)
        #expect(recent.subscriptionName == "Token Plan Plus")
        #expect(cumulative.totalTokens == 1_738_342)
        #expect(abs((cumulative.totalCost ?? 0) - 0.23) < 0.000_001)
    }

    @Test
    func `merged MiniMax sources preserve their union of history windows`() throws {
        let now = Date(timeIntervalSince1970: 1_785_427_200) // 2026-07-29 00:00:00 UTC
        let routedEntry = Self.entry(
            date: "2026-06-30",
            model: "MiniMax-M3",
            cost: 1,
            tokens: 1000,
            billingProviderID: "minimax")
        let localEntry = Self.entry(
            date: "2026-07-12",
            model: "minimax/MiniMax-M3",
            cost: 0.23,
            tokens: 1_738_342)
        let routed = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: routedEntry.totalTokens,
            last30DaysCostUSD: routedEntry.costUSD,
            currencyCode: "USD",
            historyDays: 30,
            historyCoverageIsEstablished: true,
            daily: [routedEntry],
            updatedAt: Date(timeIntervalSince1970: 1_783_396_800)) // 2026-07-05 UTC
        let local = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: localEntry.totalTokens,
            last30DaysCostUSD: localEntry.costUSD,
            currencyCode: "USD",
            historyDays: 365,
            historyCoverageIsEstablished: true,
            daily: [localEntry],
            updatedAt: now)
        let inputs = [
            SpendDashboardModel.ProviderInput(
                id: "codex",
                provider: .codex,
                displayName: "Codex",
                snapshot: routed),
            SpendDashboardModel.ProviderInput(
                id: "minimax:local",
                provider: .minimax,
                displayName: "MiniMax",
                snapshot: local),
        ]

        let recent = try #require(SpendDashboardModel.build(
            inputs: inputs,
            requestedDays: 7,
            now: now,
            calendar: Self.calendar).groups.first?.providers.first { $0.provider == .minimax })
        let cumulative = try #require(SpendDashboardModel.build(
            inputs: inputs,
            requestedDays: 365,
            now: now,
            calendar: Self.calendar).groups.first?.providers.first { $0.provider == .minimax })

        #expect(recent.totalTokens == 0)
        #expect(recent.totalCost == 0)
        #expect(cumulative.totalTokens == 1_739_342)
        #expect(abs((cumulative.totalCost ?? 0) - 1.23) < 0.000_001)
    }

    @Test
    func `model provider identity follows the model vendor instead of its harness`() {
        #expect(SpendProviderIdentity.modelProvider(
            rawName: "claude-opus-4-6-thinking",
            fallback: .antigravity) == .claude)
        #expect(SpendProviderIdentity.modelProvider(
            rawName: "gemini-3.6-flash",
            fallback: .antigravity) == .gemini)
        #expect(SpendProviderIdentity.modelProvider(rawName: "k3", fallback: .cursor) == .kimi)
        #expect(SpendProviderIdentity.modelProvider(rawName: "gpt-5.6-terra", fallback: .codex) == .openai)
        #expect(SpendProviderIdentity.modelProvider(rawName: "future-model", fallback: .cursor) == .cursor)
        #expect(SpendProviderIdentity.modelProvider(rawName: "qwen3-coder", fallback: .cursor) == .alibaba)
        #expect(SpendProviderIdentity.modelProvider(rawName: "glm-5", fallback: .cursor) == .zai)
        #expect(SpendProviderIdentity.modelProvider(rawName: "amazon.nova-pro", fallback: .cursor) == .bedrock)
        #expect(SpendProviderIdentity.modelProvider(rawName: "sonar-pro", fallback: .cursor) == .perplexity)
    }

    @Test
    func `merged same-day costs withhold when any entry lacks a price`() throws {
        // Two fragments from the same billing vendor overlap on one day; one is priced and the
        // other is token-only. The merged day must not present the priced subtotal as complete.
        let priced = Self.entry(
            date: "2026-07-24",
            model: "claude-sonnet-4",
            cost: 0.5,
            tokens: 100,
            billingProviderID: UsageProvider.claude.rawValue)
        let tokenOnly = CostUsageDailyReport.Entry(
            date: "2026-07-24",
            inputTokens: 10,
            outputTokens: 10,
            totalTokens: 20,
            costUSD: nil,
            modelsUsed: ["claude-sonnet-4"],
            modelBreakdowns: [CostUsageDailyReport.ModelBreakdown(
                modelName: "claude-sonnet-4",
                costUSD: nil,
                totalTokens: 20,
                inputTokens: 10,
                outputTokens: 10)])

        let attributed = SpendBillingAttribution.attribute([
            SpendDashboardModel.ProviderInput(
                id: "a",
                provider: .claude,
                displayName: "Claude",
                modelProviderName: "Claude",
                snapshot: Self.snapshot([priced])),
            SpendDashboardModel.ProviderInput(
                id: "b",
                provider: .claude,
                displayName: "Claude",
                modelProviderName: "Claude",
                snapshot: Self.snapshot([tokenOnly])),
        ])

        let merged = try #require(attributed.first)
        let day = try #require(merged.snapshot.daily.first)
        #expect(day.costUSD == nil)
        #expect(merged.snapshot.last30DaysCostUSD == nil)
    }

    private static func entry(
        date: String = "2026-07-24",
        model: String,
        cost: Double,
        tokens: Int,
        billingProviderID: String? = nil) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: date,
            inputTokens: tokens / 2,
            outputTokens: tokens - tokens / 2,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: [model],
            modelBreakdowns: [CostUsageDailyReport.ModelBreakdown(
                modelName: model,
                billingProviderID: billingProviderID,
                costUSD: cost,
                totalTokens: tokens,
                inputTokens: tokens / 2,
                outputTokens: tokens - tokens / 2)])
    }

    private static func snapshot(_ entries: [CostUsageDailyReport.Entry]) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: entries.compactMap(\.totalTokens).reduce(0, +),
            last30DaysCostUSD: entries.compactMap(\.costUSD).reduce(0, +),
            currencyCode: "USD",
            historyDays: 30,
            daily: entries,
            updatedAt: self.now)
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static let now = Date(timeIntervalSince1970: 1_785_024_000) // 2026-07-24 00:00:00 UTC
}
