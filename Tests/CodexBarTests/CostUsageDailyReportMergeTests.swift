import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageDailyReportMergeTests {
    @Test
    func `merged report sums overlapping day totals and model breakdowns`() {
        let native = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-04-04",
                    inputTokens: 100,
                    outputTokens: 20,
                    cacheReadTokens: 10,
                    cacheCreationTokens: nil,
                    totalTokens: 130,
                    costUSD: 1.25,
                    modelsUsed: ["gpt-5.4"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "gpt-5.4",
                            costUSD: 1.25,
                            totalTokens: 130,
                            inputTokens: 100,
                            cacheReadTokens: 10,
                            outputTokens: 20,
                            standardCostUSD: 0.75,
                            priorityCostUSD: 0.50,
                            standardTokens: 80,
                            priorityTokens: 50),
                    ]),
            ],
            summary: CostUsageDailyReport.Summary(
                totalInputTokens: 100,
                totalOutputTokens: 20,
                cacheReadTokens: 10,
                cacheCreationTokens: nil,
                totalTokens: 130,
                totalCostUSD: 1.25))
        let pi = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-04-04",
                    inputTokens: 50,
                    outputTokens: 10,
                    cacheReadTokens: 5,
                    cacheCreationTokens: 2,
                    totalTokens: 67,
                    costUSD: 0.75,
                    modelsUsed: ["gpt-5.4"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "gpt-5.4",
                            costUSD: 0.75,
                            totalTokens: 67,
                            inputTokens: 50,
                            cacheReadTokens: 5,
                            cacheCreationTokens: 2,
                            outputTokens: 10,
                            standardCostUSD: 0.25,
                            priorityCostUSD: 0.50,
                            standardTokens: 20,
                            priorityTokens: 47),
                    ]),
            ],
            summary: CostUsageDailyReport.Summary(
                totalInputTokens: 50,
                totalOutputTokens: 10,
                cacheReadTokens: 5,
                cacheCreationTokens: 2,
                totalTokens: 67,
                totalCostUSD: 0.75))

        let merged = native.merged(with: pi)
        #expect(merged.data.count == 1)
        #expect(merged.data.first?.inputTokens == 150)
        #expect(merged.data.first?.outputTokens == 30)
        #expect(merged.data.first?.cacheReadTokens == 15)
        #expect(merged.data.first?.cacheCreationTokens == 2)
        #expect(merged.data.first?.totalTokens == 197)
        #expect(abs((merged.data.first?.costUSD ?? 0) - 2.0) < 0.000001)
        #expect(merged.data.first?.modelBreakdowns == [
            CostUsageDailyReport.ModelBreakdown(
                modelName: "gpt-5.4",
                costUSD: 2.0,
                totalTokens: 197,
                inputTokens: 150,
                cacheReadTokens: 15,
                outputTokens: 30,
                standardCostUSD: 1.0,
                priorityCostUSD: 1.0,
                standardTokens: 100,
                priorityTokens: 97),
        ])
        #expect(merged.summary?.totalTokens == 197)
        #expect(abs((merged.summary?.totalCostUSD ?? 0) - 2.0) < 0.000001)
    }

    @Test
    func `merged report unions days and orders model breakdowns deterministically`() {
        let first = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-04-04",
                    inputTokens: nil,
                    outputTokens: nil,
                    cacheReadTokens: nil,
                    cacheCreationTokens: nil,
                    totalTokens: 30,
                    costUSD: 0.30,
                    modelsUsed: ["gpt-5.3-codex"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(modelName: "gpt-5.3-codex", costUSD: 0.30, totalTokens: 30),
                    ]),
            ],
            summary: nil)
        let second = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-04-05",
                    inputTokens: nil,
                    outputTokens: nil,
                    cacheReadTokens: nil,
                    cacheCreationTokens: nil,
                    totalTokens: 40,
                    costUSD: 0.40,
                    modelsUsed: ["gpt-5.4", "gpt-5.3-codex"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(modelName: "gpt-5.4", costUSD: 0.40, totalTokens: 40),
                        CostUsageDailyReport.ModelBreakdown(modelName: "gpt-5.3-codex", costUSD: 0.00, totalTokens: 0),
                    ]),
            ],
            summary: nil)

        let merged = CostUsageDailyReport.merged([first, second])
        #expect(merged.data.map(\.date) == ["2026-04-04", "2026-04-05"])
        #expect(merged.data.last?.modelBreakdowns?.map(\.modelName) == ["gpt-5.4", "gpt-5.3-codex"])
        #expect(merged.summary?.totalTokens == 70)
        #expect(abs((merged.summary?.totalCostUSD ?? 0) - 0.70) < 0.000001)
    }

    @Test
    func `merged report includes derived totals when another same day entry has explicit total`() {
        let explicit = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-04-04",
                    inputTokens: 70,
                    outputTokens: 30,
                    totalTokens: 100,
                    costUSD: 1.0,
                    modelsUsed: ["gpt-5.4"],
                    modelBreakdowns: nil),
            ],
            summary: nil)
        let derived = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-04-04",
                    inputTokens: 10,
                    outputTokens: 5,
                    cacheReadTokens: 3,
                    cacheCreationTokens: 2,
                    totalTokens: nil,
                    costUSD: 0.25,
                    modelsUsed: ["gpt-5.3-codex"],
                    modelBreakdowns: nil),
            ],
            summary: nil)

        let merged = CostUsageDailyReport.merged([explicit, derived])
        #expect(merged.data.first?.totalTokens == 120)
        #expect(merged.summary?.totalTokens == 120)
        #expect(abs((merged.data.first?.costUSD ?? 0) - 1.25) < 0.000001)
    }

    @Test
    func `merged report sums reasoning tokens and drops the bucket when any source misses it`() {
        func report(day: String, reasoning: Int?) -> CostUsageDailyReport {
            CostUsageDailyReport(
                data: [
                    CostUsageDailyReport.Entry(
                        date: day,
                        inputTokens: 100,
                        outputTokens: 30,
                        totalTokens: 130,
                        costUSD: 1.0,
                        modelsUsed: ["gpt-5.4"],
                        modelBreakdowns: [
                            CostUsageDailyReport.ModelBreakdown(
                                modelName: "gpt-5.4",
                                costUSD: 1.0,
                                totalTokens: 130,
                                inputTokens: 100,
                                outputTokens: 30,
                                reasoningTokens: reasoning),
                        ]),
                ],
                summary: nil)
        }

        let both = report(day: "2026-04-04", reasoning: 12)
            .merged(with: report(day: "2026-04-04", reasoning: 8))
        #expect(both.data.first?.modelBreakdowns?.first?.outputTokens == 60)
        #expect(both.data.first?.modelBreakdowns?.first?.reasoningTokens == 20)

        // Reasoning is a sub-bucket of output: merging must never change the output total.
        let missing = report(day: "2026-04-04", reasoning: 12)
            .merged(with: report(day: "2026-04-04", reasoning: nil))
        #expect(missing.data.first?.modelBreakdowns?.first?.outputTokens == 60)
        #expect(missing.data.first?.modelBreakdowns?.first?.reasoningTokens == nil)
    }

    @Test
    func `model breakdown decodes reasoning tokens from camel and snake case keys`() throws {
        let camel = try JSONDecoder().decode(
            CostUsageDailyReport.ModelBreakdown.self,
            from: Data(#"{"modelName":"gpt-5.4","reasoningTokens":7}"#.utf8))
        #expect(camel.reasoningTokens == 7)

        let snake = try JSONDecoder().decode(
            CostUsageDailyReport.ModelBreakdown.self,
            from: Data(#"{"modelName":"gpt-5.4","reasoning_output_tokens":9}"#.utf8))
        #expect(snake.reasoningTokens == 9)

        let absent = try JSONDecoder().decode(
            CostUsageDailyReport.ModelBreakdown.self,
            from: Data(#"{"modelName":"gpt-5.4"}"#.utf8))
        #expect(absent.reasoningTokens == nil)
    }
}
