import CodexBarCore
import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
import Testing

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

    #if canImport(SQLite3) || canImport(CSQLite3)
    @Test
    func `database records win cross store deduplication and retain pricing`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try Self.makeSessionDir(root, "ses_a")
        let created = "2026-07-10T09:00:00Z"
        let shared = Self.assistantMessage(
            id: "msg_shared",
            modelID: "claude-sonnet-4",
            created: created,
            tokens: #"{"input":10,"output":5,"cache":{"read":0,"write":0}}"#)
        let idless = Self.assistantMessage(
            id: nil,
            modelID: "claude-sonnet-4",
            created: created,
            tokens: #"{"input":2,"output":3,"cache":{"read":0,"write":0}}"#)
        try Self.write(shared, to: session.appendingPathComponent("msg_shared.json"))
        try Self.write(idless, to: session.appendingPathComponent("legacy.json"))

        func withCost(_ message: String, _ cost: Double) -> String {
            String(message.dropLast()) + ",\"cost\":\(cost)}"
        }
        try Self.createOpenCodeDatabase(
            at: root.appendingPathComponent("opencode/opencode.db"),
            messages: [withCost(shared, 1.25), withCost(idless, 0.75)])

        let snapshot = try #require(Self.scan(root: root, now: Self.date("2026-07-12T12:00:00Z")))
        #expect(snapshot.last30DaysRequests == 2)
        #expect(snapshot.last30DaysTokens == 20)
        #expect(snapshot.last30DaysCostUSD == 2)
        #expect(snapshot.daily.first?.modelBreakdowns?.first?.costUSD == 2)
    }

    @Test
    func `database records preserve provider routing evidence`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("opencode"),
            withIntermediateDirectories: true)
        let message = Self.assistantMessage(
            id: "msg-routed",
            modelID: "minimax/MiniMax-M3",
            providerID: "minimax",
            created: "2026-07-10T09:00:00Z",
            tokens: #"{"input":10,"output":5,"cache":{"read":0,"write":0}}"#)
        try Self.createOpenCodeDatabase(
            at: root.appendingPathComponent("opencode/opencode.db"),
            messages: [message])

        let snapshot = try #require(Self.scan(root: root, now: Self.date("2026-07-12T12:00:00Z")))
        let breakdown = try #require(snapshot.daily.first?.modelBreakdowns?.first)
        #expect(breakdown.billingProviderID == "minimax")
    }

    @Test
    func `scanner propagates a busy database instead of reporting empty history`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("opencode/opencode.db")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Self.createOpenCodeDatabase(at: databaseURL, messages: [
            Self.assistantMessage(
                id: "msg-a",
                modelID: "claude-sonnet-4",
                created: "2026-07-10T09:00:00Z",
                tokens: #"{"input":10,"output":5,"cache":{"read":0,"write":0}}"#),
        ])

        var writer: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &writer) == SQLITE_OK, let writer else {
            throw OpenCodeSQLiteFixtureError.open
        }
        defer {
            sqlite3_exec(writer, "ROLLBACK;", nil, nil, nil)
            sqlite3_close(writer)
        }
        guard sqlite3_exec(writer, "BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK else {
            throw OpenCodeSQLiteFixtureError.write
        }

        #expect(throws: OpenCodeSessionScanner.ScanError.databaseUnavailable) {
            _ = try Self.scanThrowing(root: root, now: Self.date("2026-07-12T12:00:00Z"))
        }
    }

    @Test
    func `scanner reports JSON file limit truncation as incomplete`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try Self.makeSessionDir(root, "ses_a")
        for index in 0..<2 {
            try Self.write(
                Self.assistantMessage(
                    id: "msg-\(index)",
                    modelID: "claude-sonnet-4",
                    created: "2026-07-10T09:00:00Z",
                    tokens: #"{"input":10,"output":5,"cache":{"read":0,"write":0}}"#),
                to: session.appendingPathComponent("msg-\(index).json"))
        }

        #expect(throws: OpenCodeSessionScanner.ScanError.historyLimitExceeded) {
            _ = try Self.scanThrowing(
                root: root,
                now: Self.date("2026-07-12T12:00:00Z"),
                maximumFiles: 1)
        }
    }
    #endif

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

    private static func scanThrowing(
        root: URL,
        now: Date,
        calendar: Calendar = Self.utcCalendar,
        maximumFiles: Int = OpenCodeSessionScanner.maximumFiles) throws -> CostUsageTokenSnapshot?
    {
        try OpenCodeSessionScanner.scanCancellable(
            environment: [OpenCodeSessionScanner.dataHomeEnvironmentKey: root.path],
            historyDays: 30,
            now: now,
            calendar: calendar,
            maximumFiles: maximumFiles)
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

    #if canImport(SQLite3) || canImport(CSQLite3)
    private static func createOpenCodeDatabase(at url: URL, messages: [String]) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw OpenCodeSQLiteFixtureError.open
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(
            database,
            "CREATE TABLE message (id TEXT PRIMARY KEY, data TEXT NOT NULL);",
            nil,
            nil,
            nil) == SQLITE_OK
        else { throw OpenCodeSQLiteFixtureError.write }

        for (index, message) in messages.enumerated() {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "INSERT INTO message (id, data) VALUES (?, ?)",
                -1,
                &statement,
                nil) == SQLITE_OK
            else { throw OpenCodeSQLiteFixtureError.write }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, "row-\(index)", -1, transient)
            sqlite3_bind_text(statement, 2, message, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw OpenCodeSQLiteFixtureError.write }
        }
    }

    private enum OpenCodeSQLiteFixtureError: Error {
        case open
        case write
    }
    #endif

    private static func assistantMessage(
        id: String?,
        modelID: String?,
        nestedModelID: String? = nil,
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
        if let providerID { fields.append(#""providerID":"\#(providerID)""#) }
        if let nestedModelID { fields.append(#""model":{"id":"\#(nestedModelID)","providerID":"test"}"#) }
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
}
