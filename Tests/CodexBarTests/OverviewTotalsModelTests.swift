import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct OverviewTotalsModelTests {
    private func input(
        _ provider: UsageProvider,
        tokens: Int?,
        cost: Double?,
        currency: String = "USD",
        historyDays: Int = 30) -> OverviewTotalsModel.ProviderInput
    {
        OverviewTotalsModel.ProviderInput(
            provider: provider,
            displayName: provider.rawValue,
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: tokens,
                last30DaysCostUSD: cost,
                currencyCode: currency,
                historyDays: historyDays,
                historyCoverageIsEstablished: true,
                daily: [],
                updatedAt: Date(timeIntervalSince1970: 0)))
    }

    @Test
    func `single currency groups sum tokens and cost`() throws {
        let model = OverviewTotalsModel.build(inputs: [
            self.input(.claude, tokens: 1_000_000, cost: 1.5),
            self.input(.codex, tokens: 2_000_000, cost: 2.5),
        ])

        let group = try #require(model?.groups.first)
        #expect(model?.providerCount == 2)
        #expect(model?.totalTokens == 3_000_000)
        #expect(group.totalTokens == 3_000_000)
        #expect(group.totalCost == 4.0)
        #expect(group.currencyCode == "USD")
        #expect(group.coveredDayCount == 30)
    }

    @Test
    func `multi currency groups are sorted by currency code`() throws {
        let model = OverviewTotalsModel.build(inputs: [
            self.input(.claude, tokens: 100, cost: 1, currency: "EUR"),
            self.input(.codex, tokens: 200, cost: 2, currency: "USD"),
        ])

        #expect(model?.groups.map(\.currencyCode) == ["EUR", "USD"])
        #expect(model?.totalTokens == 300)
        let eurGroup = try #require(model?.groups.first)
        #expect(eurGroup.totalCost == 1)
    }

    @Test
    func `preferred currency converts priced groups`() throws {
        let eurRate = try #require(CurrencyExchange.shared.rate(for: "EUR"))
        let model = OverviewTotalsModel.build(
            inputs: [
                self.input(.claude, tokens: 100, cost: 10, currency: "EUR"),
                self.input(.codex, tokens: 200, cost: 2, currency: "USD"),
            ],
            preferredCurrencyCode: "USD")

        let group = try #require(model?.groups.first)
        #expect(group.currencyCode == "USD")
        #expect(group.totalCost == 2 + 10 / eurRate)
    }

    @Test
    func `unpriced provider still contributes tokens`() throws {
        let model = OverviewTotalsModel.build(inputs: [
            self.input(.claude, tokens: 500, cost: nil),
            self.input(.codex, tokens: 300, cost: 4),
        ])

        let group = try #require(model?.groups.first)
        #expect(group.totalTokens == 800)
        #expect(group.totalCost == 4)
    }

    @Test
    func `token overflow blanks the group token total`() {
        let model = OverviewTotalsModel.build(inputs: [
            self.input(.claude, tokens: Int.max, cost: 1),
            self.input(.codex, tokens: Int.max, cost: 1),
        ])

        #expect(model?.groups.first?.totalTokens == nil)
        #expect(model?.groups.first?.totalCost == 2)
    }

    @Test
    func `non finite cost is excluded from the group total`() {
        let model = OverviewTotalsModel.build(inputs: [
            self.input(.claude, tokens: 100, cost: .infinity),
            self.input(.codex, tokens: 200, cost: 3),
        ])

        #expect(model?.groups.first?.totalCost == 3)
    }

    @Test
    func `invalid currency inputs are dropped`() throws {
        let model = OverviewTotalsModel.build(inputs: [
            self.input(.claude, tokens: 100, cost: 1, currency: "XXX"),
            self.input(.codex, tokens: 200, cost: 2),
        ])

        let group = try #require(model?.groups.first)
        #expect(group.contributions.map(\.provider) == [.codex])
        #expect(group.totalTokens == 200)
    }

    @Test
    func `empty or single provider inputs build no model`() {
        #expect(OverviewTotalsModel.build(inputs: []) == nil)
        #expect(OverviewTotalsModel.build(inputs: [
            self.input(.codex, tokens: 1, cost: 1),
        ]) == nil)
    }
}
