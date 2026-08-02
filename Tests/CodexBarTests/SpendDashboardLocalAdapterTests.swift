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

    @Test
    func `published quota snapshot is not double counted when local history loads`() async {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let quota = Self.localHistorySnapshot(tokens: 100, model: "kimi-k3", now: now)
        let local = Self.localHistorySnapshot(tokens: 21, model: "kimi-k3", now: now)
        let request = SpendDashboardLoadRequest(
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: [UsageProvider.kimi.rawValue],
                codexAccountIdentities: []),
            capturedInputs: [
                SpendDashboardModel.ProviderInput(
                    id: UsageProvider.kimi.rawValue,
                    provider: .kimi,
                    displayName: "Kimi Code CLI",
                    snapshot: quota),
            ],
            unavailableSourceIDs: [],
            codexRequests: [],
            localHistoryRequests: [
                LocalSpendHistoryRequest(
                    source: .kimiCode,
                    provider: .kimi,
                    homePath: "/synthetic/kimi"),
            ],
            now: now,
            force: false)

        let result = await SpendDashboardSource.load(
            request,
            codexSnapshotLoader: { _ in
                Issue.record("Codex loader should not run")
                return quota
            },
            kimiCodeSnapshotLoader: { context in
                #expect(context.homePath == "/synthetic/kimi")
                return local
            })

        let kimiInputs = result.inputs.filter { $0.provider == .kimi }
        #expect(kimiInputs.count == 1)
        #expect(kimiInputs.first?.id == "kimi:local")
        #expect(kimiInputs.first?.snapshot.last30DaysTokens == 21)
        #expect(result.failedSourceIDs.isEmpty)
    }

    @Test
    func `registered Copilot adapter loads through the generic local history pipeline`() async throws {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let snapshot = Self.localHistorySnapshot(tokens: 33, model: "gpt-5", now: now)
        let request = SpendDashboardLoadRequest(
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: [UsageProvider.copilot.rawValue],
                codexAccountIdentities: []),
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [],
            localHistoryRequests: [
                LocalSpendHistoryRequest(
                    source: .copilot,
                    provider: .copilot,
                    homePath: "/synthetic/copilot"),
            ],
            now: now,
            force: false)

        let result = await SpendDashboardSource.load(
            request,
            codexSnapshotLoader: { _ in
                Issue.record("Codex loader should not run")
                return snapshot
            },
            copilotSnapshotLoader: { context in
                #expect(context.homePath == "/synthetic/copilot")
                return snapshot
            })

        let input = try #require(result.inputs.first)
        #expect(input.id == "copilot:local")
        #expect(input.provider == .copilot)
        #expect(input.displayName == "GitHub Copilot")
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
