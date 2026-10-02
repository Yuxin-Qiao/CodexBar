import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageCodexCheckpointTests {
    @Test
    func `explicit checkpoint reads growth during discovery without changing preserved hydration`() async throws {
        let fixture = try CodexCurrentWindowFixture(kind: .historical)
        defer { fixture.base.remove() }
        var cache = CostUsageStoreAccess.read(
            cacheRoot: fixture.base.env.cacheRoot, calendar: fixture.base.calendar)
        let roots = try #require(cache.roots).keys.sorted()
        cache.codexSessionDiscovery = .init(
            roots: roots,
            directoryStamps: [:],
            directoryPaths: roots,
            nextDirectoryIndex: 0,
            filePaths: [fixture.pendingURL.path],
            nextFileIndex: 0,
            fileStamps: [:],
            headScan: .init(path: fixture.pendingURL.path, offset: 0),
            filePathBySessionId: [:],
            missingSessionIds: [],
            pendingSessionIds: ["fixture-parent"],
            validationDirectoryIndex: 0,
            isComplete: false)
        CostUsageStoreAccess.replace(
            cacheRoot: fixture.base.env.cacheRoot, cache: cache, calendar: fixture.base.calendar)
        let before = await fixture.base.store.readSnapshot()
        let retained = try #require(await fixture.base.cachedSnapshot())
        #expect(retained.snapshot.last30DaysTokens == 13)
        #expect(await fixture.strictSnapshot() == nil)
        let current = try #require(await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: fixture.base.now,
            historyDays: 1,
            includePiSessions: false,
            includeProjectAndSessionBreakdowns: false,
            preferCurrentCache: true,
            scannerOptions: fixture.base.options,
            environment: [:]))
        #expect(current.snapshot.last30DaysTokens == 52)
        #expect(current.snapshot.historyScanIsPartial)
        #expect(!current.snapshot.historyIsFullyScanned)
        #expect(current.staleSnapshotUpdatedAt == nil)
        #expect(await fixture.base.store.readSnapshot() == before)
        #expect(await fixture.base.cachedSnapshot()?.snapshot.last30DaysTokens == 13)
        let expanded = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: fixture.base.now,
            historyDays: 30,
            includePiSessions: false,
            preferCurrentCache: true,
            scannerOptions: fixture.base.options,
            environment: [:])
        #expect(expanded == nil)
    }

    @Test
    func `checkpoint rejects regressions in known classes even if total tokens grow`() throws {
        let now = Date()
        let old = Self.snapshot(input: 100, cached: 20, output: 10, now: now)
        let lowerCached = Self.snapshot(input: 120, cached: 10, output: 10, now: now, complete: false)
        #expect(old.mergingMonotonicCheckpoint(lowerCached, now: now, calendar: .current) == nil)
        let missingCached = Self.snapshot(input: 120, cached: nil, output: 10, now: now, complete: false)
        #expect(old.mergingMonotonicCheckpoint(missingCached, now: now, calendar: .current) == nil)
        let more = Self.snapshot(input: 120, cached: 25, output: 10, now: now, complete: false)
        let merged = try #require(old.mergingMonotonicCheckpoint(more, now: now, calendar: .current))
        #expect(merged.sessionTokens == 130)
        #expect(merged.daily.first?.cacheReadTokens == 25)
        #expect(merged.last30DaysCostUSD == 1.3)
    }

    private static func snapshot(
        input: Int, cached: Int?, output: Int, now: Date, complete: Bool = true) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: input + output,
            sessionCostUSD: Double(input + output) / 100,
            last30DaysTokens: input + output,
            last30DaysCostUSD: Double(input + output) / 100,
            historyCoverageIsEstablished: complete,
            daily: [.init(
                date: CostUsageLocalDay.key(from: now, calendar: .current),
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cached,
                totalTokens: input + output,
                costUSD: Double(input + output) / 100,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: now)
    }
}
