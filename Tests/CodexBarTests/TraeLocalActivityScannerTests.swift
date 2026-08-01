import CodexBarCore
import Foundation
import Testing

#if canImport(SQLite3) || canImport(CSQLite3)
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite3
#endif

struct TraeLocalActivityScannerTests {
    @Test
    func `scanner surfaces the selected model and last active day without token counts`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TraeLocalActivityScannerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("state.vscdb")
        let modelMap = #"{"solo_coder":"1_-_glm-5.2","builder":"0_-_kimi-k2.7-code"}"#
        try Self.createDatabase(at: database, values: [
            "4484236971871945_ai-chat:sessionRelation:globalModelMap": modelMap,
            "telemetry.lastSessionDate": "Tue, 28 Jul 2026 08:30:00 GMT",
        ])

        let snapshot = try #require(TraeLocalActivityScanner.scan(
            environment: [TraeLocalActivityScanner.databaseEnvironmentKey: database.path],
            historyDays: 30,
            now: Date(timeIntervalSince1970: 1_785_456_000), // 2026-07-30T00:00:00Z
            calendar: Self.calendar))

        #expect(snapshot.historyLabel == "Trae")
        #expect(snapshot.last30DaysTokens == nil)
        let entry = try #require(snapshot.daily.first)
        #expect(entry.totalTokens == nil)
        #expect(entry.costUSD == nil)
        // Selection-id prefixes stripped, de-duplicated, sorted case-insensitively.
        #expect(entry.modelsUsed == ["glm-5.2", "kimi-k2.7-code"])
        // Anchored on the telemetry last-session day.
        #expect(entry.date == "2026-07-28")
    }

    @Test
    func `scanner returns nil when nothing useful is stored`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TraeLocalActivityScannerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("state.vscdb")
        try Self.createDatabase(at: database, values: [:])
        let snapshot = TraeLocalActivityScanner.scan(
            environment: [TraeLocalActivityScanner.databaseEnvironmentKey: database.path],
            historyDays: 30,
            now: Date(timeIntervalSince1970: 1_785_456_000),
            calendar: Self.calendar)
        #expect(snapshot == nil)
    }

    @Test
    func `scanner omits activity when the last session predates the history window`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TraeLocalActivityScannerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("state.vscdb")
        let modelMap = #"{"solo_coder":"1_-_glm-5.2"}"#
        try Self.createDatabase(at: database, values: [
            "4484236971871945_ai-chat:sessionRelation:globalModelMap": modelMap,
            // 2026-05-01 is months before the 30-day window ending 2026-07-30.
            "telemetry.lastSessionDate": "Fri, 01 May 2026 12:00:00 GMT",
        ])

        let snapshot = TraeLocalActivityScanner.scan(
            environment: [TraeLocalActivityScanner.databaseEnvironmentKey: database.path],
            historyDays: 30,
            now: Date(timeIntervalSince1970: 1_785_456_000), // 2026-07-30T00:00:00Z
            calendar: Self.calendar)
        #expect(snapshot == nil)
    }

    private static func createDatabase(at url: URL, values: [String: String]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw TestFailure.dbOpen
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(
            db,
            "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);",
            nil,
            nil,
            nil) == SQLITE_OK
        else {
            throw TestFailure.dbWrite
        }
        for (key, value) in values {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO ItemTable (key, value) VALUES (?, ?);", -1, &stmt, nil) ==
                SQLITE_OK
            else {
                throw TestFailure.dbWrite
            }
            sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
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

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}
#endif
