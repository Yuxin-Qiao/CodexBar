import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageRetainedBreakdownTests {
    @Test
    func `disk fallback restores matching totals projects chats and sessions and revalidates ownership`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 3)
        defer { fixture.remove() }
        var cache = fixture.canonical
        let paths = cache.files.keys.sorted()
        for (index, path) in paths.enumerated() {
            let project = fixture.env.root.appendingPathComponent("synthetic-project-\(index)").path
            cache.files[path]?.projectPath = project
            cache.files[path]?.canonicalProjectPath = project
            cache.files[path]?.codexSession?.cwd = project
        }
        let marker = fixture.env.codexSessionsRoot.deletingLastPathComponent()
            .appendingPathComponent(".codex-global-state.json")
        let metadataDatabase = marker.deletingLastPathComponent().appendingPathComponent("state_5.sqlite")
        try Data().write(to: metadataDatabase)
        let metadataWriter = try BaselineSQLiteConnection(url: metadataDatabase)
        try metadataWriter.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, project_id TEXT)")
        let chatID = try #require(cache.files[paths[1]]?.sessionId)
        try JSONSerialization.data(withJSONObject: ["projectless-thread-ids": [chatID]])
            .write(to: marker, options: .atomic)
        let previous = try #require(CostUsageCodexPreviousReport.capturing(
            cache: cache,
            range: fixture.range,
            sessionRoots: CostUsageScanner.codexSessionsRoots(options: fixture.options)))
        #expect(previous.breakdowns?.projects.count == 2)
        #expect(previous.breakdowns?.projects.filter(\.isProjectless).count == 1)
        cache.codexPreviousReport = previous
        cache.codexScanCatchUpPending = true
        cache.lastScanUnixMs += 60000
        for path in paths {
            cache.files[path]?.codexScanComplete = false
        }
        #expect(!fixture.save(cache).catchUpRequired)

        let restored = try #require(await fixture.cachedSnapshot(details: true))
        #expect(restored.snapshot.daily == previous.report.data)
        #expect(restored.snapshot.projects.sorted { ($0.path ?? "") < ($1.path ?? "") }
            == previous.breakdowns?.projects.sorted { ($0.path ?? "") < ($1.path ?? "") })
        #expect(restored.snapshot.sessions.count == 2)
        #expect(restored.snapshot.projectBreakdownAvailability == .complete)
        #expect(restored.snapshot.sessionBreakdownAvailability == .complete)
        #expect(restored.snapshot.breakdownsAreStale)
        #expect(restored.snapshot.updatedAt == fixture.now)
        #expect(restored.lastRefreshAt == nil)

        // A transiently unreadable marker does not erase an already validated classification.
        try Data("invalid".utf8).write(to: marker, options: .atomic)
        var current = cache
        current.codexPreviousReport = nil
        current.codexScanCatchUpPending = false
        for path in paths {
            current.files[path]?.codexScanComplete = true
        }
        #expect(!fixture.save(current).catchUpRequired)
        let currentUnknown = try #require(await fixture.cachedSnapshot(details: true))
        #expect(currentUnknown.snapshot.historyCoverageIsEstablished)
        #expect(currentUnknown.snapshot.projectBreakdownAvailability == .unavailable)
        #expect(currentUnknown.snapshot.sessionBreakdownAvailability == .complete)
        #expect(currentUnknown.snapshot.last30DaysTokens == restored.snapshot.last30DaysTokens)
        #expect(!fixture.save(cache).catchUpRequired)
        let unreadable = try #require(await fixture.cachedSnapshot(details: true))
        #expect(unreadable.snapshot.projects.filter(\.isProjectless).count == 1)
        try FileManager.default.moveItem(at: metadataDatabase, to: metadataDatabase.appendingPathExtension("offline"))
        let offline = try #require(await fixture.cachedSnapshot(details: true))
        #expect(offline.snapshot.projects.filter(\.isProjectless).count == 1)
        let reassignedOffline = CostUsageFetcher.codexBreakdownsWithMetadata(
            offline.snapshot.sessions,
            projects: offline.snapshot.projects,
            projectSessionIDs: previous.breakdowns?.projectSessionIDs ?? [:],
            sessionsRoot: fixture.env.codexSessionsRoot,
            environment: [:],
            preserveRetainedClassification: true,
            projectMetadataLookup: { _, _, _ in ([:], [], [chatID]) })
        #expect(reassignedOffline.projects.allSatisfy { !$0.isProjectless })
        #expect(reassignedOffline.projects.allSatisfy { !$0.name.hasPrefix("Independent chat") })
        // Successful current ownership metadata always wins over the retained classification.
        try JSONSerialization.data(withJSONObject: [
            "projectless-thread-ids": [chatID],
            "thread-project-assignments": [chatID: ["projectId": "synthetic-owned-project"]],
        ]).write(to: marker, options: .atomic)
        let reassigned = try #require(await fixture.cachedSnapshot(details: true))
        #expect(reassigned.snapshot.projects.allSatisfy { !$0.isProjectless })
        #expect(reassigned.snapshot.last30DaysTokens == restored.snapshot.last30DaysTokens)
        #expect(reassigned.snapshot.last30DaysCostUSD == restored.snapshot.last30DaysCostUSD)
    }

    @Test
    func `legacy reports keep unknown detail and omitted requests`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 1, rowsPerFile: 2, incomplete: true)
        defer { fixture.remove() }
        var cache = fixture.canonical
        let previous = try #require(CostUsageCodexPreviousReport(
            report: fixture.fullReport(cache),
            cache: cache,
            reportSinceKey: fixture.range.sinceKey,
            reportUntilKey: fixture.range.untilKey))
        let data = try JSONEncoder().encode(previous)
        #expect(try #require(String(data: data, encoding: .utf8)).contains("breakdowns") == false)
        cache.codexPreviousReport = try JSONDecoder().decode(CostUsageCodexPreviousReport.self, from: data)
        #expect(!fixture.save(cache).catchUpRequired)
        let restored = try #require(await fixture.cachedSnapshot(details: true))
        #expect(restored.snapshot.last30DaysTokens == fixture.rowCount * 13)
        #expect(restored.snapshot.historyCoverageIsEstablished)
        #expect(restored.snapshot.projects.isEmpty)
        #expect(restored.snapshot.projectBreakdownAvailability == .unavailable)
        #expect(restored.snapshot.sessionBreakdownAvailability == .unavailable)
        let totalsOnly = try #require(await fixture.cachedSnapshot(details: false))
        #expect(totalsOnly.snapshot.projectBreakdownAvailability == .notRequested)
        #expect(totalsOnly.snapshot.sessionBreakdownAvailability == .notRequested)
    }

    @Test
    func `unrecognized optional detail preserves the accounting report`() throws {
        let fixture = try ReadWorkFixture(fileCount: 1, rowsPerFile: 1)
        defer { fixture.remove() }
        let previous = try #require(CostUsageCodexPreviousReport.capturing(
            cache: fixture.canonical,
            range: fixture.range,
            sessionRoots: CostUsageScanner.codexSessionsRoots(options: fixture.options)))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(previous)) as? [String: Any])
        object["breakdowns"] = ["version": 999, "unknown": "future payload"]
        let decoded = try JSONDecoder().decode(
            CostUsageCodexPreviousReport.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.breakdowns == nil)
        #expect(decoded.report.data == previous.report.data)
        #expect(decoded.updatedAt == previous.updatedAt)
    }

    @Test
    func `detail payload is bounded and wider retained session amounts are never reused`() throws {
        let fixture = try ReadWorkFixture(fileCount: 1, rowsPerFile: 1)
        defer { fixture.remove() }
        var previous = try #require(CostUsageCodexPreviousReport.capturing(
            cache: fixture.canonical,
            range: fixture.range,
            sessionRoots: CostUsageScanner.codexSessionsRoots(options: fixture.options)))
        let details = try #require(previous.breakdowns)
        #expect(CostUsageCodexRetainedBreakdowns(
            projects: details.projects,
            sessions: details.sessions.map(\.value),
            projectSessionIDs: details.projectSessionIDs,
            projectAvailability: .complete,
            maximumPayloadBytes: 1) == nil)
        previous.scanSinceKey = "2026-07-31"
        previous.data.append(.init(CostUsageDailyReport.Entry(
            date: "2026-07-31",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 999,
            costUSD: 99,
            modelsUsed: nil,
            modelBreakdowns: nil)))
        let scoped = previous.report(in: fixture.range)
        #expect(scoped.data.map(\.date) == [ReadWorkFixture.day])
        #expect(scoped.summary?.totalTokens == fixture.rowCount * 13)
        let retained = previous.retainedBreakdowns(
            range: fixture.range, sessionsRoot: fixture.env.codexSessionsRoot, environment: [:])
        #expect(retained.projects.isEmpty && retained.sessions.isEmpty)
        #expect(retained.projectAvailability == .unavailable)
        #expect(retained.sessionAvailability == .unavailable)
    }
}
