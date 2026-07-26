import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SpendDashboardLocalHistoryRecoveryTests {
    @Test
    func `successful local history clears unavailable live provider warning`() async {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let request = SpendDashboardLoadRequest(
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: [UsageProvider.minimax.rawValue],
                codexAccountIdentities: []),
            capturedInputs: [],
            unavailableSourceIDs: [UsageProvider.minimax.rawValue],
            codexRequests: [],
            miniMaxHomePath: "/synthetic/minimax-home",
            now: now,
            force: true)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 10,
            last30DaysCostUSD: 0.23,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-07-15",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 10,
                    costUSD: 0.23,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: now)

        let result = await SpendDashboardSource.load(
            request,
            codexSnapshotLoader: { _ in
                Issue.record("No Codex source should be loaded")
                return snapshot
            },
            miniMaxSnapshotLoader: { context in
                #expect(context.homePath == "/synthetic/minimax-home")
                return snapshot
            })

        #expect(result.inputs.map(\.id) == ["minimax:local"])
        #expect(result.failedSourceIDs.isEmpty)
    }

    @Test
    func `manual refresh reconciliation retains successful local history`() async throws {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let configuration = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.kimi.rawValue],
            codexAccountIdentities: [])
        let request = SpendDashboardLoadRequest(
            configuration: configuration,
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [],
            now: now,
            force: true)
        let input = SpendDashboardModel.ProviderInput(
            id: "kimi:local",
            provider: .kimi,
            displayName: "Kimi Code CLI",
            snapshot: Self.snapshot(now: now, cost: 2))
        let defaults = try #require(UserDefaults(suiteName: "SpendDashboardLocalHistoryRecoveryTests"))
        defaults.removePersistentDomain(forName: "SpendDashboardLocalHistoryRecoveryTests")
        let controller = SpendDashboardController(
            userDefaults: defaults,
            requestBuilder: { _ in request },
            loader: { _ in
                SpendDashboardLoadResult(inputs: [input], failedSourceIDs: [])
            })

        controller.update(configuration: configuration, force: true)
        await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.model.groups.first?.providers.map(\.id) == ["kimi:local"])
        #expect(controller.model.groups.first?.totalCost == 2)
    }

    private static func snapshot(now: Date, cost: Double) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 10,
            last30DaysCostUSD: cost,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-07-15",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 10,
                    costUSD: cost,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: now)
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for controller state")
    }
}
