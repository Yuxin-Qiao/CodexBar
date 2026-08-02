import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendDashboardLocalAdapterTests {
    @Test
    func `registered Qwen Code adapter loads through the generic local history pipeline`() async throws {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let snapshot = Self.localHistorySnapshot(tokens: 21, model: "qwen3-coder-plus", now: now)
        let request = SpendDashboardLoadRequest(
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: [UsageProvider.qwencloud.rawValue],
                codexAccountIdentities: []),
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [],
            localHistoryRequests: [
                LocalSpendHistoryRequest(
                    source: .qwenCode,
                    provider: .qwencloud,
                    homePath: "/synthetic/qwen-code"),
            ],
            now: now,
            force: false)

        let result = await SpendDashboardSource.load(
            request,
            codexSnapshotLoader: { _ in
                Issue.record("Codex loader should not run")
                return snapshot
            },
            qwenCodeSnapshotLoader: { context in
                #expect(context.homePath == "/synthetic/qwen-code")
                return snapshot
            })

        let input = try #require(result.inputs.first)
        #expect(input.id == "qwencloud:local")
        #expect(input.provider == .qwencloud)
        #expect(input.displayName == "Qwen Code CLI")
        #expect(result.failedSourceIDs.isEmpty)
    }

    private static func localHistorySnapshot(
        tokens: Int,
        model: String,
        now: Date) -> CostUsageTokenSnapshot
    {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-07-16",
            inputTokens: tokens,
            outputTokens: 0,
            totalTokens: tokens,
            requestCount: 1,
            costUSD: nil,
            modelsUsed: [model],
            modelBreakdowns: [.init(modelName: model, costUSD: nil, totalTokens: tokens)])
        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: tokens,
            last30DaysCostUSD: nil,
            currencyCode: "XXX",
            daily: [entry],
            updatedAt: now)
    }
}
