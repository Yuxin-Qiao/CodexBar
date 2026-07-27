import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendToolPresentationTests {
    @Test
    func `tool identity separates product family from client kind`() {
        #expect(SpendToolIdentity.resolve(
            provider: .codex,
            sourceName: "Codex",
            providerName: "Codex") == .init(displayName: "Codex Desktop", kind: .desktop))
        #expect(SpendToolIdentity.resolve(
            provider: .cursor,
            sourceName: "Cursor",
            providerName: "Cursor") == .init(displayName: "Cursor", kind: .ide))
        #expect(SpendToolIdentity.resolve(
            provider: .kimi,
            sourceName: "Kimi Code CLI",
            providerName: "Kimi") == .init(displayName: "Kimi Code CLI", kind: .cli))
        #expect(SpendToolIdentity.resolve(
            provider: .qoder,
            sourceName: "Qoder",
            providerName: "Qoder") == .init(displayName: "Qoder", kind: .ide))
    }

    @Test
    func `tool cards aggregate token buckets once per source`() throws {
        let model = Self.model()
        let groups = SpendClientBreakdown.groups(from: model.modelAnalysis)
        let codex = try #require(groups.first { $0.provider == .codex })
        let cursor = try #require(groups.first { $0.provider == .cursor })

        #expect(codex.kind == .desktop)
        #expect(codex.inputTokens == 40)
        #expect(codex.outputTokens == 10)
        #expect(codex.cacheReadTokens == 20)
        #expect(codex.reasoningTokens == 4)
        #expect(cursor.kind == .ide)
        #expect(cursor.inputTokens == 20)
        #expect(cursor.outputTokens == 10)
        #expect(cursor.cacheReadTokens == 10)
        #expect(cursor.reasoningTokens == 2)
    }

    @Test
    func `token chart partitions each day by semantic token bucket`() {
        let presentation = SpendModelsTokenChartPresentation(analysis: Self.model().modelAnalysis)

        #expect(presentation.points.map(\.kind) == [
            .input,
            .cacheRead,
            .output,
            .reasoning,
        ])
        #expect(presentation.points.map(\.value) == [60, 30, 14, 6])
        #expect(presentation.points.last?.stackEnd == 110)
    }

    @Test
    func `daily spend details preserve tool type models amounts and tokens`() throws {
        let group = try #require(Self.model().groups.first)
        let detail = try #require(group.dailySpendDetails.first)
        let codex = try #require(detail.tools.first { $0.provider == .codex })

        #expect(codex.kind == .desktop)
        #expect(codex.displayName == "Codex Desktop")
        #expect(codex.tokens == 70)
        #expect(codex.cost == 1)
        #expect(codex.models.first?.displayName == "GPT-5 Test")
        #expect(codex.models.first?.modelProvider == .openai)
    }

    private static func model() -> SpendDashboardModel {
        let inputs = [
            Self.input(
                provider: .codex,
                name: "Codex",
                tokens: .init(input: 40, output: 10, cache: 20, reasoning: 4),
                cost: 1),
            Self.input(
                provider: .cursor,
                name: "Cursor",
                tokens: .init(input: 20, output: 10, cache: 10, reasoning: 2),
                cost: 2),
        ]
        return SpendDashboardModel.build(
            inputs: inputs,
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar)
    }

    private static func input(
        provider: UsageProvider,
        name: String,
        tokens: TokenBuckets,
        cost: Double) -> SpendDashboardModel.ProviderInput
    {
        let total = tokens.input + tokens.output + tokens.cache
        let breakdown = CostUsageDailyReport.ModelBreakdown(
            modelName: "gpt-5-test",
            costUSD: cost,
            totalTokens: total,
            inputTokens: tokens.input,
            cacheReadTokens: tokens.cache,
            cacheCreationTokens: 0,
            outputTokens: tokens.output,
            reasoningTokens: tokens.reasoning)
        let entry = CostUsageDailyReport.Entry(
            date: "2026-07-27",
            inputTokens: tokens.input,
            outputTokens: tokens.output,
            cacheReadTokens: tokens.cache,
            cacheCreationTokens: 0,
            totalTokens: total,
            costUSD: cost,
            modelsUsed: ["gpt-5-test"],
            modelBreakdowns: [breakdown])
        return SpendDashboardModel.ProviderInput(
            provider: provider,
            displayName: name,
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: total,
                last30DaysCostUSD: cost,
                currencyCode: "USD",
                historyDays: 7,
                daily: [entry],
                updatedAt: Self.now))
    }

    private struct TokenBuckets {
        let input: Int
        let output: Int
        let cache: Int
        let reasoning: Int
    }

    private static let now = Date(timeIntervalSince1970: 1_785_240_000)
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}
