import CodexBarCore
import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
import Testing

#if canImport(SQLite3) || canImport(CSQLite3)
struct MiniMaxSessionScannerTests {
    @Test
    func `scanner observes committed rows still present in the live WAL`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiniMaxSessionScannerWALTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("v2/sqlite/runtime-state.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        var writer: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &writer) == SQLITE_OK, let writer else {
            throw SQLiteFixtureError.open
        }
        defer { sqlite3_close(writer) }
        guard sqlite3_exec(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;", nil, nil, nil)
            == SQLITE_OK
        else {
            throw SQLiteFixtureError.schema
        }
        try Self.createSchema(in: writer)
        guard sqlite3_wal_checkpoint_v2(writer, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK else {
            throw SQLiteFixtureError.schema
        }
        try Self.insertCurrentRow(in: writer)

        let snapshot = try #require(MiniMaxSessionScanner.scan(
            environment: [MiniMaxSessionScanner.homeEnvironmentKey: root.path],
            historyDays: 30,
            now: Date(timeIntervalSince1970: 1_785_033_600),
            calendar: Self.calendar,
            modelsDevCacheRoot: root.appendingPathComponent("empty-pricing", isDirectory: true)))

        #expect(snapshot.last30DaysRequests == 1)
        #expect(snapshot.last30DaysTokens == 350)
    }

    @Test
    func `scanner prices MiniMax M3 even when the models catalog is empty`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiniMaxSessionScannerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("v2/sqlite/runtime-state.sqlite")
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Self.createDatabase(at: database)

        let now = Date(timeIntervalSince1970: 1_785_033_600) // 2026-07-26 UTC
        let cacheRoot = root.appendingPathComponent("empty-model-pricing-cache", isDirectory: true)
        let snapshot = try #require(MiniMaxSessionScanner.scan(
            environment: [MiniMaxSessionScanner.homeEnvironmentKey: root.path],
            historyDays: 30,
            now: now,
            calendar: Self.calendar,
            modelsDevCacheRoot: cacheRoot))

        #expect(snapshot.currencyCode == "USD")
        #expect(snapshot.costSource == .estimated)
        #expect(snapshot.last30DaysTokens == 350)
        #expect(snapshot.last30DaysRequests == 1)
        #expect(abs((snapshot.last30DaysCostUSD ?? 0) - 0.000_102) < 0.000_000_001)
        let breakdown = try #require(snapshot.daily.first?.modelBreakdowns?.first)
        #expect(breakdown.modelName == "minimax/MiniMax-M3")
        #expect(breakdown.reasoningTokens == 20)
        #expect(abs((breakdown.costUSD ?? 0) - 0.000_102) < 0.000_000_001)
    }

    @Test
    func `scanner filters old database rows before decoding`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiniMaxSessionScannerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("v2/sqlite/runtime-state.sqlite")
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Self.createDatabase(at: database, oldRowCount: 200)

        var checks = 0
        let snapshot = try MiniMaxSessionScanner.scanCancellable(
            environment: [MiniMaxSessionScanner.homeEnvironmentKey: root.path],
            historyDays: 30,
            now: Date(timeIntervalSince1970: 1_785_033_600),
            calendar: Self.calendar,
            checkCancellation: {
                checks += 1
                if checks > 10 {
                    throw CancellationError()
                }
            })

        #expect(snapshot?.last30DaysRequests == 1)
        #expect(checks <= 10)
    }

    @Test
    func `scanner propagates a busy database instead of reporting empty history`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiniMaxSessionScannerBusyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("v2/sqlite/runtime-state.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Self.createDatabase(at: databaseURL)

        var writer: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &writer) == SQLITE_OK, let writer else {
            throw SQLiteFixtureError.open
        }
        defer {
            sqlite3_exec(writer, "ROLLBACK;", nil, nil, nil)
            sqlite3_close(writer)
        }
        guard sqlite3_exec(writer, "BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK else {
            throw SQLiteFixtureError.schema
        }

        #expect(throws: MiniMaxSessionScanner.ScanError.databaseUnavailable) {
            try MiniMaxSessionScanner.scanCancellable(
                environment: [MiniMaxSessionScanner.homeEnvironmentKey: root.path],
                historyDays: 30,
                now: Date(timeIntervalSince1970: 1_785_033_600),
                calendar: Self.calendar)
        }
    }

    private static func createDatabase(at url: URL, oldRowCount: Int = 0) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw SQLiteFixtureError.open
        }
        defer { sqlite3_close(database) }
        try Self.createSchema(in: database)
        try Self.insertCurrentRow(in: database)
        guard oldRowCount > 0 else { return }
        for index in 0..<oldRowCount {
            let oldSQL = """
            INSERT INTO local_runtime_token_usage (
              session_id, agent_name, framework_type, turn_id, model, ts,
              input_tokens, output_tokens, reasoning_tokens, cache_read_tokens,
              cache_write_tokens, cost_usd
            ) VALUES (
              'old-\(index)', 'main', 'agent', 'turn-\(index)', 'minimax/MiniMax-M3', 1609459200000,
              100, 50, 20, 200, 0, 0
            );
            """
            guard sqlite3_exec(database, oldSQL, nil, nil, nil) == SQLITE_OK else {
                throw SQLiteFixtureError.schema
            }
        }
    }

    private static func createSchema(in database: OpaquePointer) throws {
        let sql = """
        CREATE TABLE local_runtime_token_usage (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id TEXT NOT NULL,
          agent_name TEXT NOT NULL,
          framework_type TEXT NOT NULL,
          turn_id TEXT,
          model TEXT,
          ts INTEGER NOT NULL,
          input_tokens INTEGER NOT NULL,
          output_tokens INTEGER NOT NULL,
          reasoning_tokens INTEGER NOT NULL,
          cache_read_tokens INTEGER NOT NULL,
          cache_write_tokens INTEGER NOT NULL,
          cost_usd REAL,
          raw TEXT
        );
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteFixtureError.schema
        }
    }

    private static func insertCurrentRow(in database: OpaquePointer) throws {
        let sql = """
        INSERT INTO local_runtime_token_usage (
          session_id, agent_name, framework_type, turn_id, model, ts,
          input_tokens, output_tokens, reasoning_tokens, cache_read_tokens,
          cache_write_tokens, cost_usd
        ) VALUES (
          'session-1', 'main', 'agent', 'turn-1', 'minimax/MiniMax-M3', 1785033600000,
          100, 50, 20, 200, 0, 0
        );
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteFixtureError.schema
        }
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private enum SQLiteFixtureError: Error {
        case open
        case schema
    }
}
#endif
