import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct SpendDashboardScanBudgetTests {
    @Test
    func `empty codex history loads separate spend and activity snapshots`() async {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let recorder = SpendDashboardScanContextRecorder()
        let account = Self.account(id: "inactive", cacheIdentity: "inactive-cache")
        let request = Self.request(account: account, now: now, force: false)

        let result = await SpendDashboardSource.load(request, codexSnapshotLoader: { context in
            await recorder.record(context)
            return Self.snapshot(context: context, tokens: 0, cost: 0)
        })
        let contexts = await recorder.contexts

        #expect(result.inputs.count == 1)
        #expect(result.inputs.first?.id == "codex:inactive")
        #expect(result.inputs.first?.snapshot.daily.isEmpty == true)
        #expect(result.failedSourceIDs.isEmpty)
        #expect(contexts.count == 2)
        #expect(contexts.first?.account == account)
        #expect(contexts.first?.cacheRoot.lastPathComponent == "inactive-cache")
        #expect(contexts.first?.now == now)
        #expect(contexts.first?.force == false)
        #expect(contexts.first?.historyDays == 30)
        #expect(contexts.first?.refreshPricingInBackground == false)
        #expect(contexts.first?.includePiSessions == false)
        #expect(contexts.last?.historyDays == 365)
        #expect(contexts.last?.force == false)
        #expect(result.inputs.first?.snapshot.historyDays == 30)
        #expect(result.inputs.first?.tokenActivitySnapshot.historyDays == 365)
    }

    @Test
    func `forced dashboard refresh preserves the normal scan budget`() async {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let recorder = SpendDashboardScanContextRecorder()
        let account = Self.account(id: "account", cacheIdentity: "scan-budget")

        _ = await SpendDashboardSource.load(
            Self.request(account: account, now: now, force: true),
            codexSnapshotLoader: { context in
                await recorder.record(context)
                return Self.snapshot(context: context, tokens: 0, cost: 0)
            })
        let contexts = await recorder.contexts

        #expect(SpendDashboardSource.scanDays == 30)
        #expect(SpendDashboardSource.activityScanDays == 365)
        #expect(contexts.map(\.historyDays) == [30, 365])
        #expect(contexts.map(\.force) == [true, false])
    }

    @Test
    func `annual activity scan failure retains the normal spend snapshot`() async {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let account = Self.account(id: "account", cacheIdentity: "activity-failure")
        let result = await SpendDashboardSource.load(
            Self.request(account: account, now: now, force: false),
            codexSnapshotLoader: { context in
                if context.historyDays == SpendDashboardSource.activityScanDays {
                    throw CocoaError(.fileReadUnknown)
                }
                return Self.snapshot(context: context, tokens: 10, cost: 1)
            })

        #expect(result.failedSourceIDs.isEmpty)
        #expect(result.inputs.count == 1)
        #expect(result.inputs.first?.snapshot.historyDays == 30)
        #expect(result.inputs.first?.tokenActivitySnapshot.historyDays == 30)
    }

    @Test
    func `annual activity cache limits rescans and expires on schedule`() async throws {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let account = Self.account(id: "account", cacheIdentity: "activity-cache")
        let cache = SpendDashboardCodexActivitySnapshotCache(refreshInterval: 15 * 60)
        let recorder = SpendDashboardScanContextRecorder()
        let context = Self.context(account: account, now: now)

        _ = try await cache.load(context) { loadContext in
            await recorder.record(loadContext)
            return Self.snapshot(context: loadContext, tokens: 10, cost: 1)
        }
        _ = try await cache.load(context) { loadContext in
            await recorder.record(loadContext)
            return Self.snapshot(context: loadContext, tokens: 20, cost: 2)
        }
        let cachedContexts = await recorder.contexts
        #expect(cachedContexts.count == 1)

        let expiredContext = Self.context(account: account, now: now.addingTimeInterval(15 * 60))
        let expired = try await cache.load(expiredContext) { loadContext in
            await recorder.record(loadContext)
            return Self.snapshot(context: loadContext, tokens: 30, cost: 3)
        }
        #expect(expired.last30DaysTokens == 30)
        let refreshedContexts = await recorder.contexts
        #expect(refreshedContexts.count == 2)
    }

    private static func account(id: String, cacheIdentity: String) -> CodexSpendScanRequest {
        CodexSpendScanRequest(
            id: id,
            displayName: "Codex",
            source: .profileHome(path: "/synthetic/codex-home"),
            homePath: "/synthetic/codex-home",
            authFingerprint: nil,
            authFileWasReadable: false,
            cacheIdentity: cacheIdentity)
    }

    private static func request(
        account: CodexSpendScanRequest,
        now: Date,
        force: Bool) -> SpendDashboardLoadRequest
    {
        SpendDashboardLoadRequest(
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: [UsageProvider.codex.rawValue],
                codexAccountIdentities: ["\(account.id)|\(account.cacheIdentity)"]),
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [account],
            now: now,
            force: force)
    }

    private static func context(
        account: CodexSpendScanRequest,
        now: Date) -> CodexSpendSnapshotLoadContext
    {
        CodexSpendSnapshotLoadContext(
            account: account,
            cacheRoot: URL(fileURLWithPath: "/synthetic/cache", isDirectory: true),
            now: now,
            force: false,
            historyDays: SpendDashboardSource.activityScanDays,
            refreshPricingInBackground: false,
            includePiSessions: false)
    }

    private nonisolated static func snapshot(
        context: CodexSpendSnapshotLoadContext,
        tokens: Int,
        cost: Double) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: tokens,
            sessionCostUSD: cost,
            last30DaysTokens: tokens,
            last30DaysCostUSD: cost,
            historyDays: context.historyDays,
            daily: [],
            updatedAt: context.now)
    }
}

private actor SpendDashboardScanContextRecorder {
    private(set) var contexts: [CodexSpendSnapshotLoadContext] = []

    func record(_ context: CodexSpendSnapshotLoadContext) {
        self.contexts.append(context)
    }
}
