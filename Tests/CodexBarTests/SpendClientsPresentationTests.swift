import Foundation
import Testing
@testable import CodexBar

struct SpendClientsPresentationTests {
    @Test
    func `model detail text includes all buckets and messages`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let text = SpendClientModelDetailText.detailText(model: Self.model(
                tokens: 53_700_000,
                inputTokens: 1_200_000,
                outputTokens: 77900,
                cacheReadTokens: 52_400_000,
                cacheCreationTokens: 0,
                reasoningTokens: 27300,
                requestCount: 403))
            #expect(
                text
                    == "54M tokens · Input 1.2M · Output 78K · Cache read 52M · Reasoning 27K · 403 messages")
        }
    }

    @Test
    func `model detail text skips missing and zero buckets`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let text = SpendClientModelDetailText.detailText(model: Self.model(
                tokens: 1000,
                inputTokens: nil,
                outputTokens: 500,
                cacheReadTokens: 0,
                cacheCreationTokens: nil,
                reasoningTokens: nil,
                requestCount: nil))
            #expect(text == "1K tokens · Output 500")
        }
    }

    @Test
    func `model detail text is empty when no data is available`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let text = SpendClientModelDetailText.detailText(model: Self.model())
            #expect(text.isEmpty)
        }
    }

    private static func model(
        tokens: Int? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        requestCount: Int? = nil) -> SpendClientModel
    {
        SpendClientModel(
            id: "model",
            displayName: "model",
            modelProvider: .openai,
            tokens: tokens,
            cost: nil,
            costIsEstimated: false,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            reasoningTokens: reasoningTokens,
            requestCount: requestCount)
    }

    @Test
    func `model metric prefers cost then falls back to tokens`() {
        #expect(SpendClientModelMetricText.text(cost: 1.5, tokens: 1000, currencyCode: "USD") == "$1.50")
        #expect(SpendClientModelMetricText.text(cost: nil, tokens: 1000, currencyCode: "USD") == "1K")
        #expect(SpendClientModelMetricText.text(cost: nil, tokens: nil, currencyCode: "USD") == "—")
    }

    @Test
    func `client breakdown passes per-model buckets into group models`() throws {
        let analysis = SpendDashboardModel.ModelAnalysis(
            rows: [
                SpendDashboardModel.ModelAnalysisRow(
                    id: "gpt-x",
                    displayName: "gpt-x",
                    rawModelNames: ["gpt-x"],
                    providers: [.openai],
                    providerNames: ["Codex"],
                    contributions: [
                        SpendDashboardModel.ModelSourceContribution(
                            sourceID: "codex",
                            provider: .openai,
                            sourceName: "Codex Desktop",
                            providerName: "Codex",
                            rawModelNames: ["gpt-x"],
                            totalTokens: 10000,
                            inputTokens: 6000,
                            outputTokens: 3000,
                            cacheReadTokens: 1000,
                            cacheCreationTokens: 200,
                            reasoningTokens: 300,
                            requestCount: 25,
                            coveredDayCount: 30,
                            projectCount: 2,
                            sessionCount: 3,
                            estimatedCost: 1.5,
                            costIsEstimated: true),
                    ],
                    totalTokens: 10000,
                    inputTokens: 6000,
                    outputTokens: 3000,
                    estimatedCost: 1.5,
                    cacheReadTokens: 1000,
                    cacheCreationTokens: 200,
                    reasoningTokens: 300,
                    costIsEstimated: true),
            ],
            dailyValues: [],
            trackedTokenTotal: 10000,
            pricedCostTotal: 1.5,
            sourceCount: 1,
            tokenCoverage: .complete,
            costCoverage: .complete)

        let groups = SpendClientBreakdown.groups(from: analysis)
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.displayTitle == "Codex Desktop")
        #expect(group.providerName == "Codex")
        #expect(group.models.count == 1)
        let model = try #require(group.models.first)
        #expect(model.displayName == "gpt-x")
        #expect(model.tokens == 10000)
        #expect(model.cost == 1.5)
        #expect(model.costIsEstimated)
        #expect(model.inputTokens == 6000)
        #expect(model.outputTokens == 3000)
        #expect(model.cacheReadTokens == 1000)
        #expect(model.cacheCreationTokens == 200)
        #expect(model.reasoningTokens == 300)
        #expect(model.requestCount == 25)
    }
}
