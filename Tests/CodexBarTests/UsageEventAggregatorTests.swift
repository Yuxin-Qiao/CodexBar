import Foundation
import Testing

@testable import CodexBarCore

@Suite
struct UsageEventAggregatorTests {
    private let now = Date(timeIntervalSince1970: 1_785_283_200)

    @Test
    func `cache-inclusive input is split using the total cross-check`() {
        // input(1100) + output(500) == total(1600), so the cached prefix is already inside input.
        let snapshot = UsageEventAggregator.aggregate(
            events: [UnifiedUsageEvent(
                day: "2026-07-28",
                model: "glm-5.2",
                inputTokens: 1100,
                outputTokens: 500,
                totalTokens: 1600,
                cacheReadTokens: 900,
                pricingProviderIDs: [])],
            historyDays: 30,
            now: self.now,
            options: .init(historyLabel: "Test"))
        let entry = snapshot?.daily.first
        #expect(entry?.inputTokens == 200)
        #expect(entry?.cacheReadTokens == 900)
        #expect(entry?.outputTokens == 500)
        #expect(entry?.totalTokens == 1600)
    }

    @Test
    func `cache-exclusive input is kept without double counting`() {
        // input(200) + cacheRead(900) + output(500) == total(1600): input is already uncached.
        let snapshot = UsageEventAggregator.aggregate(
            events: [UnifiedUsageEvent(
                day: "2026-07-28",
                model: "glm-5.2",
                inputTokens: 200,
                outputTokens: 500,
                totalTokens: 1600,
                cacheReadTokens: 900,
                pricingProviderIDs: [])],
            historyDays: 30,
            now: self.now,
            options: .init(historyLabel: "Test"))
        #expect(snapshot?.daily.first?.inputTokens == 200)
        #expect(snapshot?.daily.first?.totalTokens == 1600)
    }

    @Test
    func `missing total falls back to subtracting the cached prefix`() {
        let snapshot = UsageEventAggregator.aggregate(
            events: [UnifiedUsageEvent(
                day: "2026-07-28",
                model: "qwen3-coder-plus",
                inputTokens: 330,
                outputTokens: 57,
                totalTokens: nil,
                cacheReadTokens: 220,
                pricingProviderIDs: [])],
            historyDays: 30,
            now: self.now,
            options: .init(historyLabel: "Test"))
        #expect(snapshot?.daily.first?.inputTokens == 110)
        #expect(snapshot?.daily.first?.totalTokens == 387)
    }

    @Test
    func `provider-reported cost is trusted and not re-priced`() {
        let snapshot = UsageEventAggregator.aggregate(
            events: [UnifiedUsageEvent(
                day: "2026-07-28",
                model: "glm-5.2",
                inputTokens: 100,
                outputTokens: 50,
                providerCostUSD: 0.5,
                pricingProviderIDs: ["zai"])],
            historyDays: 30,
            now: self.now,
            options: .init(historyLabel: "Test"))
        #expect(snapshot?.daily.first?.costUSD == 0.5)
    }

    @Test
    func `unpriced token usage keeps the day cost nil rather than a partial total`() {
        let snapshot = UsageEventAggregator.aggregate(
            events: [UnifiedUsageEvent(
                day: "2026-07-28",
                model: "unknown-model",
                inputTokens: 100,
                outputTokens: 50,
                pricingProviderIDs: ["no-such-provider"])],
            historyDays: 30,
            now: self.now,
            options: .init(historyLabel: "Test"))
        // Tokens are real but unpriced, so the cost must stay nil, not a fabricated partial sum.
        #expect(snapshot?.daily.first?.totalTokens == 150)
        #expect(snapshot?.daily.first?.costUSD == nil)
    }

    @Test
    func `degraded model-only events surface without token totals`() {
        let snapshot = UsageEventAggregator.aggregate(
            events: [
                UnifiedUsageEvent(day: "2026-07-28", model: "claude-opus-4-8"),
                UnifiedUsageEvent(day: "2026-07-28", model: "gpt-5"),
            ],
            historyDays: 30,
            now: self.now,
            options: .init(historyLabel: "Test"))
        let entry = snapshot?.daily.first
        #expect(entry?.totalTokens == nil)
        #expect(entry?.costUSD == nil)
        #expect(entry?.modelsUsed == ["claude-opus-4-8", "gpt-5"])
        #expect(entry?.modelBreakdowns == nil)
        // A fully degraded snapshot carries no headline token total.
        #expect(snapshot?.last30DaysTokens == nil)
    }

    @Test
    func `per-event billing evidence wins over the tool default`() {
        let snapshot = UsageEventAggregator.aggregate(
            events: [UnifiedUsageEvent(
                day: "2026-07-28",
                model: "claude-haiku-4-5",
                billingProviderID: "claude",
                inputTokens: 100,
                outputTokens: 50,
                pricingProviderIDs: [])],
            historyDays: 30,
            now: self.now,
            options: .init(historyLabel: "Test", defaultBillingProviderID: "copilot"))
        #expect(snapshot?.daily.first?.modelBreakdowns?.first?.billingProviderID == "claude")
    }
}
