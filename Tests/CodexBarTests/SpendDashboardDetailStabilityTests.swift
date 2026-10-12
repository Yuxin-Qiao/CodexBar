import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct SpendDashboardDetailStabilityTests {
    @Test(arguments: [CostUsageBreakdownAvailability.notRequested, .unavailable, .complete])
    func `totals only refresh retains complete details but confirmed empty replaces them`(
        availability: CostUsageBreakdownAvailability) async throws
    {
        let gate = SpendDashboardPendingLoads<SpendDashboardLoadResult>()
        defer { gate.close() }
        let configuration = Self.configuration
        let old = Self.input(cost: 8, details: true, availability: .complete)
        let controller = SpendDashboardController(
            userDefaults: InMemoryUserDefaults(),
            requestBuilder: { _ in Self.request(configuration) },
            cachedLoader: { _ in .init(inputs: [old], failedSourceIDs: []) },
            loader: { _ in
                await (try? gate.load()) ?? .init(inputs: [], failedSourceIDs: [])
            }, nowProvider: { Self.now })
        controller.update(configuration: configuration)
        try await gate.waitForPendingCount(1)
        #expect(controller.model.groups.first?.projects.count == 2)
        let next = Self.input(cost: availability == .complete ? 0 : 9, details: false, availability: availability)
        gate.resume(returning: .init(inputs: [next], failedSourceIDs: []))
        try await Self.waitUntil { !controller.isRefreshing }
        let group = try #require(controller.model.groups.first)
        if availability == .complete {
            #expect(group.totalCost == 0)
            #expect(group.projects.isEmpty)
            #expect(group.sessions.isEmpty)
            #expect(controller.retainedDetailSourceIDs.isEmpty)
        } else {
            #expect(group.totalCost == 8)
            #expect(group.projects.count == 2)
            #expect(group.projects.filter(\.isProjectless).count == 1)
            #expect(group.sessions.count == 1)
            #expect(controller.retainedDetailSourceIDs == ["codex:account"])
        }
        let emptyDay = Self.now.addingTimeInterval(-7 * 86400)
        controller.selectDay(emptyDay)
        #expect(controller.model.groups.first?.projects.isEmpty == true)
        #expect(spendDashboardAvailableDetailSections(
            hasProjects: false, hasSessions: false, supportsCodexDetails: true)
            == [.providers, .projects, .chats, .sessions])
    }

    @Test
    func `retained details cannot cross a history window`() async throws {
        let old = Self.input(cost: 8, details: true, availability: .complete, historyDays: 90)
        let next = Self.input(cost: 9, details: false, availability: .unavailable)
        let controller = SpendDashboardController(
            userDefaults: InMemoryUserDefaults(),
            requestBuilder: { _ in Self.request(Self.configuration) },
            cachedLoader: { _ in .init(inputs: [old], failedSourceIDs: []) },
            loader: { _ in .init(inputs: [next], failedSourceIDs: []) },
            nowProvider: { Self.now })
        controller.update(configuration: Self.configuration)
        try await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.first?.totalCost == 9)
        #expect(controller.model.groups.first?.projects.isEmpty == true)
        #expect(controller.retainedDetailSourceIDs.isEmpty)
    }

    @Test
    func `capability survives loading unavailable and empty sources and respects hiding`() {
        for state in [
            SpendSourcePublication.State.loading,
            .unavailable,
            .confirmedEmpty,
            .available,
            .staleLastKnown,
        ] {
            let source = SpendSourcePublication(
                id: "codex:account",
                provider: .codex,
                displayName: "Synthetic account",
                role: .subscription,
                state: state)
            #expect(spendDashboardSupportsCodexDetails(
                sources: [source], hiddenSourceIDs: [], hideNativeCodexWhenOpenCodexPresent: false))
            #expect(!spendDashboardSupportsCodexDetails(
                sources: [source], hiddenSourceIDs: [source.id], hideNativeCodexWhenOpenCodexPresent: false))
        }
    }

    @Test
    func `OpenCodex replacement retains native details without counting their totals twice`() throws {
        let native = Self.input(cost: 8, details: true, availability: .complete)
        let replacement = SpendDashboardModel.ProviderInput(
            id: SpendDashboardModel.openCodexSourceID,
            provider: .codex,
            displayName: "OpenCodex",
            snapshot: Self.input(cost: 13, details: false, availability: .notRequested).snapshot,
            sourceKind: .openCodex)
        let expected = SpendDashboardModel.build(inputs: [replacement], now: Self.now)
        let combined = SpendDashboardModel.build(
            inputs: [native, replacement], now: Self.now, hideNativeCodexWhenOpenCodexPresent: true)
        let group = try #require(combined.groups.first)
        let totals = try #require(expected.groups.first)
        #expect(group.totalCost == totals.totalCost)
        #expect(group.totalTokens == totals.totalTokens)
        #expect(group.providers == totals.providers)
        #expect(group.dailyPoints == totals.dailyPoints)
        #expect(group.models == totals.models)
        #expect(combined.tokenActivity == expected.tokenActivity)
        #expect(group.projects.count == 2)
        #expect(group.projects.filter(\.isProjectless).count == 1)
        #expect(group.sessions.count == 1)
        #expect(group.projectBreakdownAvailability == .complete)
        #expect(group.detailsExcludedFromTotals)
        let hidden = SpendDashboardModel.build(
            inputs: [native, replacement],
            now: Self.now,
            hiddenSourceIDs: [native.id],
            hideNativeCodexWhenOpenCodexPresent: true)
        #expect(hidden.groups.first?.projects.isEmpty == true)
        #expect(hidden.groups.first?.detailsExcludedFromTotals == false)
        let fallback = SpendDashboardModel.build(
            inputs: [native], now: Self.now, hideNativeCodexWhenOpenCodexPresent: true)
        #expect(fallback.groups.first?.projects == group.projects)
        #expect(fallback.groups.first?.detailsExcludedFromTotals == false)
        let emptyDay = Self.now.addingTimeInterval(-7 * 86400)
        let selected = SpendDashboardModel.build(
            inputs: [native, replacement],
            now: Self.now,
            hideNativeCodexWhenOpenCodexPresent: true,
            selectedDay: emptyDay)
        #expect(selected.groups.first?.projects.isEmpty == true)
    }

    @Test(arguments: [SpendSourcePublication.State.loading, .available, .staleLastKnown, .unavailable, .confirmedEmpty])
    func `OpenCodex state cannot remove native detail capability`(state: SpendSourcePublication.State) {
        let sources = [
            SpendSourcePublication(
                id: "codex:account",
                provider: .codex,
                displayName: "Codex",
                role: .subscription,
                state: .available),
            SpendSourcePublication(
                id: SpendDashboardModel.openCodexSourceID,
                provider: .codex,
                displayName: "OpenCodex",
                role: .enrichment,
                state: state),
        ]
        #expect(spendDashboardSupportsCodexDetails(
            sources: sources, hiddenSourceIDs: [], hideNativeCodexWhenOpenCodexPresent: true))
        #expect(!spendDashboardSupportsCodexDetails(
            sources: sources, hiddenSourceIDs: ["codex:account"], hideNativeCodexWhenOpenCodexPresent: true))
    }

    @Test
    func `empty complete detail is distinct from loading failure and a retained result`() {
        #expect(spendDashboardDetailMessage(
            availability: .complete,
            hasRows: false,
            isRefreshing: false,
            hasFailedSources: false,
            isStale: false) == L("No records in this time range."))
        #expect(spendDashboardDetailMessage(
            availability: .unavailable,
            hasRows: false,
            isRefreshing: true,
            hasFailedSources: false,
            isStale: false) == L("Loading details…"))
        #expect(spendDashboardDetailMessage(
            availability: .unavailable,
            hasRows: false,
            isRefreshing: false,
            hasFailedSources: true,
            isStale: false) == L("Details unavailable. Refresh to try again."))
        #expect(spendDashboardDetailMessage(
            availability: .complete,
            hasRows: true,
            isRefreshing: false,
            hasFailedSources: false,
            isStale: true) == L("Showing the last available details."))
    }

    private nonisolated static let now = Date(timeIntervalSince1970: 1_784_179_200)
    private static let configuration = SpendDashboardConfiguration(
        costUsageEnabled: true,
        providerIDs: [UsageProvider.codex.rawValue],
        codexAccountIdentities: ["account|owner"],
        bucketTimeZoneIdentifier: "UTC")

    private static func request(_ configuration: SpendDashboardConfiguration) -> SpendDashboardLoadRequest {
        .init(
            configuration: configuration,
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [],
            now: self.now,
            force: false)
    }

    private static func input(
        cost: Double,
        details: Bool,
        availability: CostUsageBreakdownAvailability,
        historyDays: Int = 30) -> SpendDashboardModel.ProviderInput
    {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-07-15",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: cost == 0 ? 0 : 80,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
        let projects: [CostUsageProjectBreakdown] = details ? [false, true].map { chat in
            let part = CostUsageDailyReport.Entry(
                date: entry.date,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: 40,
                costUSD: 4,
                modelsUsed: nil,
                modelBreakdowns: nil)
            return CostUsageProjectBreakdown(
                name: chat ? "Synthetic chat" : "Synthetic project",
                path: chat ? "/synthetic/chat" : "/synthetic/project",
                totalTokens: 40,
                totalCostUSD: 4,
                daily: [part],
                modelBreakdowns: nil,
                isProjectless: chat)
        } : []
        let sessions: [CostUsageSessionBreakdown] = details ? [.init(
            sessionID: "synthetic",
            lastActivity: Self.now,
            inputTokens: nil,
            cachedInputTokens: nil,
            outputTokens: nil,
            totalTokens: 40,
            requestCount: 1,
            costUSD: 4,
            modelBreakdowns: [])] : []
        return .init(
            id: "codex:account",
            provider: .codex,
            displayName: "Synthetic Codex",
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: entry.totalTokens,
                last30DaysCostUSD: cost,
                historyDays: historyDays,
                daily: cost == 0 ? [] : [entry],
                projects: projects,
                sessions: sessions,
                projectBreakdownAvailability: availability,
                sessionBreakdownAvailability: availability,
                updatedAt: Self.now))
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw SpendDetailTestError.timeout
    }
}

private enum SpendDetailTestError: Error {
    case timeout
}
