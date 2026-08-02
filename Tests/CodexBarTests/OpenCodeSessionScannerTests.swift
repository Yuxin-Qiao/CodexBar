import CodexBarCore
import Foundation
import Testing
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

struct OpenCodeSessionScannerTests {
    @Test
    func `scanner aggregates assistant messages across sessions and models`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionA = try Self.makeSessionDir(root, "ses_a")
        let sessionB = try Self.makeSessionDir(root, "ses_b")

        try Self.write(Self.assistantMessage(
            id: "msg_001",
            modelID: "claude-sonnet-4",
            created: "2026-07-10T09:00:00Z",
            tokens: #"{"input":100,"output":50,"reasoning":10,"cache":{"read":20,"write":5}}"#,
            completed: true), to: sessionA.appendingPathComponent("msg_001.json"))
        try Self.write(
            Self.assistantMessage(
                id: "msg_002",
                modelID: "gpt-5",
                created: "2026-07-11T10:00:00Z",
                tokens: #"{"input":3,"output":4,"cache":{"read":1,"write":2}}"#),
            to: sessionA.appendingPathComponent("msg_002.json"))
        try Self.write(
            Self.assistantMessage(
                id: "msg_003",
                modelID: "claude-sonnet-4",
                created: "2026-07-10T11:00:00Z",
                tokens: #"{"input":7,"output":8,"reasoning":1,"cache":{"read":0,"write":0}}"#),
            to: sessionB.appendingPathComponent("msg_003.json"))
        // Non-JSON files in the storage tree are ignored.
        try Self.write("not json", to: sessionB.appendingPathComponent("notes.txt"))

        let snapshot = try #require(Self.scan(root: root, now: Self.date("2026-07-12T12:00:00Z")))

        #expect(snapshot.currencyCode == "XXX")
        #expect(snapshot.historyLabel == "OpenCode")
        #expect(snapshot.last30DaysTokens == 211)
        #expect(snapshot.last30DaysRequests == 3)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.daily.map(\.date) == ["2026-07-10", "2026-07-11"])

        // Reasoning stays folded into billing output and is also surfaced as the reasoning
        // bucket; cache.write maps to cacheCreationTokens.
        let first = snapshot.daily[0]
        #expect(first.inputTokens == 107)
        #expect(first.outputTokens == 69)
        #expect(first.cacheReadTokens == 20)
        #expect(first.cacheCreationTokens == 5)
        #expect(first.totalTokens == 201)
        #expect(first.requestCount == 2)
        #expect(first.costUSD == nil)
        #expect(first.modelsUsed == ["claude-sonnet-4"])
        let firstBreakdown = try #require(first.modelBreakdowns?.first)
        #expect(firstBreakdown.modelName == "claude-sonnet-4")
        #expect(firstBreakdown.inputTokens == 107)
        #expect(firstBreakdown.outputTokens == 69)
        #expect(firstBreakdown.cacheReadTokens == 20)
        #expect(firstBreakdown.cacheCreationTokens == 5)
        #expect(firstBreakdown.reasoningTokens == 11)
        #expect(firstBreakdown.totalTokens == 201)
        #expect(firstBreakdown.requestCount == 2)
        #expect(firstBreakdown.costUSD == nil)

        let second = snapshot.daily[1]
        #expect(second.inputTokens == 3)
        #expect(second.outputTokens == 4)
        #expect(second.cacheReadTokens == 1)
        #expect(second.cacheCreationTokens == 2)
        #expect(second.totalTokens == 10)
        #expect(second.requestCount == 1)
        #expect(second.modelsUsed == ["gpt-5"])
        // A message without the optional `reasoning` key reports no reasoning bucket.
        #expect(second.modelBreakdowns?.first?.reasoningTokens == nil)
    }

    @Test
    func `scanner retains billing ownership evidence from json and nested model`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionA = try Self.makeSessionDir(root, "ses_a")
        let sessionB = try Self.makeSessionDir(root, "ses_b")
        try Self.write(
            Self.assistantMessage(
                id: "msg_001",
                modelID: "claude-sonnet-4",
                providerID: "anthropic",
                created: "2026-07-10T09:00:00Z",
                tokens: #"{"input":100,"output":50,"cache":{"read":20,"write":5}}"#),
            to: sessionA.appendingPathComponent("msg_001.json"))
        try Self.write(
            Self.assistantMessage(
                id: "msg_002",
                modelID: "gpt-5",
                nestedModelID: "gpt-5",
                nestedProviderID: "openai",
                created: "2026-07-11T10:00:00Z",
                tokens: #"{"input":3,"output":4,"cache":{"read":1,"write":2}}"#),
            to: sessionA.appendingPathComponent("msg_002.json"))
        // Legacy record without ownership evidence stays nil.
        try Self.write(
            Self.assistantMessage(
                id: "msg_003",
                modelID: "gemini-2.5-pro",
                created: "2026-07-10T11:00:00Z",
                tokens: #"{"input":7,"output":8,"cache":{"read":0,"write":0}}"#),
            to: sessionB.appendingPathComponent("msg_003.json"))

        let snapshot = try #require(Self.scan(root: root, now: Self.date("2026-07-12T12:00:00Z")))

        let breakdowns = snapshot.daily.flatMap { $0.modelBreakdowns ?? [] }
        #expect(breakdowns.map(\.billingProviderID) == ["anthropic", nil, "openai"])
    }

    @Test
    func `scanner buckets usage by local day across midnight`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try Self.makeSessionDir(root, "ses_a")
        // 23:30 at GMT+8 on 2026-07-10.
        try Self.write(
            Self.assistantMessage(
                id: "msg_001",
                modelID: "claude-sonnet-4",
                created: "2026-07-10T15:30:00Z",
                tokens: #"{"input":1,"output":2,"cache":{"read":0,"write":0}}"#),
            to: session.appendingPathComponent("msg_001.json"))
        // 00:30 at GMT+8 on 2026-07-11.
        try Self.write(
            Self.assistantMessage(
                id: "msg_002",
                modelID: "claude-sonnet-4",
                created: "2026-07-10T16:30:00Z",
                tokens: #"{"input":3,"output":4,"cache":{"read":0,"write":0}}"#),
            to: session.appendingPathComponent("msg_002.json"))

        let snapshot = try #require(Self.scan(
            root: root,
            now: Self.date("2026-07-12T12:00:00Z"),
            calendar: Self.gmtPlus8Calendar))

        #expect(snapshot.daily.map(\.date) == ["2026-07-10", "2026-07-11"])
        #expect(snapshot.daily.map(\.requestCount) == [1, 1])
        #expect(snapshot.daily.map(\.totalTokens) == [3, 7])
    }

    @Test
    func `scanner prefilters by file mtime and drops records outside the window`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try Self.makeSessionDir(root, "ses_a")

        // mtime older than the window: skipped without parsing, even for in-window timestamps.
        let oldFile = session.appendingPathComponent("msg_old.json")
        try Self.write(
            Self.assistantMessage(
                id: "msg_old",
                modelID: "claude-sonnet-4",
                created: "2026-07-12T09:00:00Z",
                tokens: #"{"input":100,"output":100,"cache":{"read":0,"write":0}}"#),
            to: oldFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Self.date("2026-06-02T12:00:00Z")],
            ofItemAtPath: oldFile.path)
        // Fresh mtime but a record older than the window: dropped by the day filter.
        try Self.write(
            Self.assistantMessage(
                id: "msg_stale",
                modelID: "claude-sonnet-4",
                created: "2026-06-02T09:00:00Z",
                tokens: #"{"input":200,"output":200,"cache":{"read":0,"write":0}}"#),
            to: session.appendingPathComponent("msg_stale.json"))
        try Self.write(
            Self.assistantMessage(
                id: "msg_ok",
                modelID: "claude-sonnet-4",
                created: "2026-07-12T09:00:00Z",
                tokens: #"{"input":5,"output":6,"cache":{"read":0,"write":0}}"#),
            to: session.appendingPathComponent("msg_ok.json"))

        let snapshot = try #require(Self.scan(root: root, now: Self.date("2026-07-12T12:00:00Z")))

        #expect(snapshot.daily.map(\.date) == ["2026-07-12"])
        #expect(snapshot.last30DaysRequests == 1)
        #expect(snapshot.last30DaysTokens == 11)
    }

    @Test
    func `scanner skips corrupt files and non assistant or model less messages`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try Self.makeSessionDir(root, "ses_a")

        try Self.write("this is not json", to: session.appendingPathComponent("msg_garbage.json"))
        try Self.write(Self.assistantMessage(
            id: "msg_user",
            modelID: "claude-sonnet-4",
            created: "2026-07-10T09:00:00Z",
            tokens: #"{"input":10,"output":5,"cache":{"read":0,"write":0}}"#,
            role: "user"), to: session.appendingPathComponent("msg_user.json"))
        // Role-less payloads are v2 SQLite rows, never valid JSON message files.
        try Self.write(Self.assistantMessage(
            id: "msg_norole",
            modelID: "claude-sonnet-4",
            created: "2026-07-10T09:00:00Z",
            tokens: #"{"input":10,"output":5,"cache":{"read":0,"write":0}}"#,
            role: nil), to: session.appendingPathComponent("msg_norole.json"))
        try Self.write(
            Self.assistantMessage(
                id: "msg_nomodel",
                modelID: nil,
                created: "2026-07-10T09:00:00Z",
                tokens: #"{"input":10,"output":5,"cache":{"read":0,"write":0}}"#),
            to: session.appendingPathComponent("msg_nomodel.json"))
        // v2-style nested model object resolves when the top-level modelID is absent.
        try Self.write(
            Self.assistantMessage(
                id: "msg_nested",
                modelID: nil,
                nestedModelID: "claude-sonnet-4",
                created: "2026-07-10T09:00:00Z",
                tokens: #"{"input":10,"output":5,"cache":{"read":1,"write":2}}"#),
            to: session.appendingPathComponent("msg_nested.json"))

        let snapshot = try #require(Self.scan(root: root, now: Self.date("2026-07-12T12:00:00Z")))

        #expect(snapshot.daily.map(\.date) == ["2026-07-10"])
        #expect(snapshot.last30DaysRequests == 1)
        #expect(snapshot.last30DaysTokens == 18)
        #expect(snapshot.daily.first?.modelsUsed == ["claude-sonnet-4"])
        #expect(snapshot.daily.first?.cacheReadTokens == 1)
        #expect(snapshot.daily.first?.cacheCreationTokens == 2)
    }

    @Test
    func `scanner skips negative token values and overflowing accumulations`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try Self.makeSessionDir(root, "ses_a")

        try Self.write(
            Self.assistantMessage(
                id: "msg_neg",
                modelID: "claude-sonnet-4",
                created: "2026-07-10T09:00:00Z",
                tokens: #"{"input":10,"output":5,"cache":{"read":-5,"write":0}}"#),
            to: session.appendingPathComponent("msg_neg.json"))
        try Self.write(
            Self.assistantMessage(
                id: "msg_neg_reasoning",
                modelID: "claude-sonnet-4",
                created: "2026-07-10T09:01:00Z",
                tokens: #"{"input":10,"output":5,"reasoning":-1,"cache":{"read":0,"write":0}}"#),
            to: session.appendingPathComponent("msg_neg_reasoning.json"))
        try Self.write(
            Self.assistantMessage(
                id: "msg_huge",
                modelID: "claude-sonnet-4",
                created: "2026-07-10T09:02:00Z",
                tokens: #"{"input":9223372036854775807,"output":0,"cache":{"read":0,"write":0}}"#),
            to: session.appendingPathComponent("msg_huge.json"))
        try Self.write(
            Self.assistantMessage(
                id: "msg_small",
                modelID: "claude-sonnet-4",
                created: "2026-07-10T09:03:00Z",
                tokens: #"{"input":10,"output":0,"cache":{"read":0,"write":0}}"#),
            to: session.appendingPathComponent("msg_small.json"))

        let snapshot = try #require(Self.scan(root: root, now: Self.date("2026-07-12T12:00:00Z")))

        // Only the Int.max record survives; the follow-up record overflows the accumulator and
        // is dropped without poisoning the bucket.
        #expect(snapshot.last30DaysRequests == 1)
        #expect(snapshot.last30DaysTokens == Int.max)
        #expect(snapshot.daily.first?.inputTokens == Int.max)
    }

    @Test
    func `scanner deduplicates forked message copies by id then file stem`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionA = try Self.makeSessionDir(root, "ses_a")
        let sessionB = try Self.makeSessionDir(root, "ses_b")
        let sessionFork = try Self.makeSessionDir(root, "ses_fork")

        try Self.write(
            Self.assistantMessage(
                id: "msg_shared",
                modelID: "claude-sonnet-4",
                created: "2026-07-10T09:00:00Z",
                tokens: #"{"input":10,"output":1,"cache":{"read":0,"write":0}}"#),
            to: sessionA.appendingPathComponent("msg_a.json"))
        // Same embedded id under a forked session directory collapses into the first copy.
        try Self.write(
            Self.assistantMessage(
                id: "msg_shared",
                modelID: "claude-sonnet-4",
                created: "2026-07-10T09:00:00Z",
                tokens: #"{"input":10,"output":1,"cache":{"read":0,"write":0}}"#),
            to: sessionFork.appendingPathComponent("msg_copy.json"))
        // Without an embedded id the file stem is the dedup key, so the fork's copy collapses too.
        try Self.write(
            Self.assistantMessage(
                id: nil,
                modelID: "claude-sonnet-4",
                created: "2026-07-10T09:00:00Z",
                tokens: #"{"input":5,"output":5,"cache":{"read":0,"write":0}}"#),
            to: sessionA.appendingPathComponent("msg_stem.json"))
        try Self.write(
            Self.assistantMessage(
                id: nil,
                modelID: "claude-sonnet-4",
                created: "2026-07-10T09:00:00Z",
                tokens: #"{"input":5,"output":5,"cache":{"read":0,"write":0}}"#),
            to: sessionB.appendingPathComponent("msg_stem.json"))
        try Self.write(
            Self.assistantMessage(
                id: "msg_distinct",
                modelID: "claude-sonnet-4",
                created: "2026-07-10T09:00:00Z",
                tokens: #"{"input":2,"output":2,"cache":{"read":0,"write":0}}"#),
            to: sessionB.appendingPathComponent("msg_distinct.json"))

        let snapshot = try #require(Self.scan(root: root, now: Self.date("2026-07-12T12:00:00Z")))

        #expect(snapshot.daily.map(\.date) == ["2026-07-10"])
        #expect(snapshot.last30DaysRequests == 3)
        #expect(snapshot.last30DaysTokens == 25)
        #expect(snapshot.daily.first?.inputTokens == 17)
        #expect(snapshot.daily.first?.outputTokens == 8)
    }

    @Test
    func `scanner honors XDG_DATA_HOME override and returns nil for empty directories`() throws {
        let emptyRoot = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: emptyRoot) }

        #expect(Self.scan(root: emptyRoot, now: Self.date("2026-07-12T12:00:00Z")) == nil)

        let dataDir = emptyRoot.appendingPathComponent("opencode/storage/message", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        #expect(Self.scan(root: emptyRoot, now: Self.date("2026-07-12T12:00:00Z")) == nil)

        let fixtureRoot = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let session = try Self.makeSessionDir(fixtureRoot, "ses_a")
        try Self.write(
            Self.assistantMessage(
                id: "msg_001",
                modelID: "claude-sonnet-4",
                created: "2026-07-10T09:00:00Z",
                tokens: #"{"input":1,"output":2,"cache":{"read":0,"write":0}}"#),
            to: session.appendingPathComponent("msg_001.json"))

        let snapshot = try #require(Self.scan(root: fixtureRoot, now: Self.date("2026-07-12T12:00:00Z")))
        #expect(snapshot.last30DaysTokens == 3)
        #expect(snapshot.historyLabel == "OpenCode")
    }

    @Test
    func `db priced day plus unpriced json day withholds the headline cost`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeDatabase(root, rows: [
            (
                id: "db-1",
                created: "2026-07-27T10:00:00Z",
                tokens: #"{"input":100,"output":50,"reasoning":0,"cache":{"read":0,"write":0}}"#,
                cost: 0.01),
        ])
        let session = try Self.makeSessionDir(root, "ses_legacy")
        try Self.write(
            Self.assistantMessage(
                id: "msg_001",
                modelID: "gpt-5",
                created: "2026-07-28T10:00:00Z",
                tokens: #"{"input":3,"output":4,"cache":{"read":0,"write":0}}"#),
            to: session.appendingPathComponent("msg_001.json"))

        let snapshot = try #require(Self.scan(root: root, now: Self.date("2026-07-28T12:00:00Z")))
        // The priced DB day stays visible, but the unpriced JSON day withholds the headline:
        // publishing 0.01 as the 30-day total would read as complete history.
        #expect(snapshot.daily.first?.costUSD == 0.01)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.currencyCode == "XXX")
        #expect(snapshot.costSource == .estimated)
    }

    @Test
    func `db priced snapshot reports provider-reported cost source`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeDatabase(root, rows: [
            (
                id: "db-1",
                created: "2026-07-27T10:00:00Z",
                tokens: #"{"input":100,"output":50,"reasoning":0,"cache":{"read":0,"write":0}}"#,
                cost: 0.01),
        ])

        let snapshot = try #require(Self.scan(root: root, now: Self.date("2026-07-28T12:00:00Z")))
        #expect(snapshot.last30DaysCostUSD == 0.01)
        #expect(snapshot.currencyCode == "USD")
        #expect(snapshot.costSource == .providerReported)
        #expect(snapshot.daily.first?.modelBreakdowns?.first?.billingProviderID == "anthropic")
    }

    // MARK: - Fixtures

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static let gmtPlus8Calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return calendar
    }()

    private static func scan(
        root: URL,
        now: Date,
        calendar: Calendar = Self.utcCalendar) -> CostUsageTokenSnapshot?
    {
        OpenCodeSessionScanner.scan(
            environment: [OpenCodeSessionScanner.dataHomeEnvironmentKey: root.path],
            historyDays: 30,
            now: now,
            calendar: calendar)
    }

    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func makeSessionDir(_ root: URL, _ sessionID: String) throws -> URL {
        let dir = root.appendingPathComponent("opencode/storage/message/\(sessionID)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func assistantMessage(
        id: String?,
        modelID: String?,
        nestedModelID: String? = nil,
        nestedProviderID: String? = nil,
        providerID: String? = nil,
        created: String,
        tokens: String,
        role: String?? = "assistant",
        completed: Bool = false) -> String
    {
        var fields: [String] = []
        if let id { fields.append(#""id":"\#(id)""#) }
        fields.append(#""sessionID":"ses""#)
        if let role = role.flatMap(\.self) { fields.append(#""role":"\#(role)""#) }
        if let modelID { fields.append(#""modelID":"\#(modelID)""#) }
        if let nestedModelID {
            var nested = #""model":{"id":"\#(nestedModelID)""#
            if let nestedProviderID { nested += #","provider":"\#(nestedProviderID)""# }
            nested += "}"
            fields.append(nested)
        }
        if let providerID { fields.append(#""providerID":"\#(providerID)""#) }
        fields.append(#""tokens":"# + tokens)
        var time = #""created":"# + "\(Self.ms(created))"
        if completed { time += #","completed":"# + "\(Self.ms(created) + 1000)" }
        fields.append(#""time":{"# + time + "}")
        return "{" + fields.joined(separator: ",") + "}"
    }

    private static func ms(_ iso: String) -> Int {
        Int(self.date(iso).timeIntervalSince1970 * 1000)
    }

    private static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso) ?? Date(timeIntervalSince1970: 0)
    }

    private static func write(_ content: String, to url: URL) throws {
        try (content + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func makeDatabase(
        _ root: URL,
        rows: [(id: String, created: String, tokens: String, cost: Double?)]) throws
    {
        let opencodeDir = root.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: opencodeDir, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(opencodeDir.appendingPathComponent("opencode.db").path, &db) == SQLITE_OK,
              let db
        else {
            throw TestFailure.dbOpen
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "CREATE TABLE message (data TEXT, time_created INTEGER);", nil, nil, nil) ==
            SQLITE_OK
        else {
            throw TestFailure.dbWrite
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for row in rows {
            var data = #"{"id":"\#(row.id)","role":"assistant","modelID":"claude-sonnet-4","tokens":\#(row.tokens),"#
            if let cost = row.cost {
                data += #""cost":\#(cost),"#
            }
            data += #""providerID":"anthropic","time":{"created":\#(Self.ms(row.created))}}"#
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "INSERT INTO message (data, time_created) VALUES (?, ?);",
                -1,
                &stmt,
                nil) == SQLITE_OK
            else {
                throw TestFailure.dbWrite
            }
            sqlite3_bind_text(stmt, 1, data, -1, transient)
            sqlite3_bind_int64(stmt, 2, Int64(Self.ms(row.created)))
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                sqlite3_finalize(stmt)
                throw TestFailure.dbWrite
            }
            sqlite3_finalize(stmt)
        }
    }

    private enum TestFailure: Error {
        case dbOpen
        case dbWrite
    }
}
