import CodexBarCore
import Foundation
import Testing

#if canImport(SQLite3) || canImport(CSQLite3)
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite3
#endif

struct CursorLocalActivityScannerTests {
    @Test
    func `scanner aggregates per-day model activity without token counts`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CursorLocalActivityScannerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tracking = root.appendingPathComponent("ai-tracking", isDirectory: true)
        try FileManager.default.createDirectory(at: tracking, withIntermediateDirectories: true)
        let database = tracking.appendingPathComponent("ai-code-tracking.db")
        // 2026-07-28 and 2026-07-29 (epoch ms), each with two models and a blank model to skip.
        try Self.createDatabase(at: database, rows: [
            (1_785_283_200_000, "Kimi K3"), // 2026-07-28T00:00:00Z
            (1_785_283_800_000, "default"),
            (1_785_284_000_000, ""), // skipped: empty model
            (1_785_369_600_000, "MiniMax-M3"), // 2026-07-29T00:00:00Z
            (1_785_369_900_000, "Kimi K3"),
        ])

        let snapshot = try #require(CursorLocalActivityScanner.scan(
            environment: [CursorLocalActivityScanner.homeEnvironmentKey: root.path],
            historyDays: 60,
            now: Date(timeIntervalSince1970: 1_785_456_000), // 2026-07-30T00:00:00Z
            calendar: Self.calendar))

        #expect(snapshot.historyLabel == "Cursor")
        #expect(snapshot.last30DaysTokens == nil)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.last30DaysRequests == nil)
        #expect(snapshot.daily.count == 2)
        let first = try #require(snapshot.daily.first)
        #expect(first.totalTokens == nil)
        #expect(first.costUSD == nil)
        #expect(first.requestCount == nil)
        #expect(first.modelsUsed == ["default", "Kimi K3"])
        let second = snapshot.daily[1]
        #expect(second.modelsUsed == ["Kimi K3", "MiniMax-M3"])
    }

    @Test
    func `scanner returns nil when the database is missing`() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CursorLocalActivityScannerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = CursorLocalActivityScanner.scan(
            environment: [CursorLocalActivityScanner.homeEnvironmentKey: root.path],
            historyDays: 30,
            now: Date(timeIntervalSince1970: 1_785_456_000),
            calendar: Self.calendar)
        #expect(snapshot == nil)
    }

    private static func createDatabase(at url: URL, rows: [(Int64, String)]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw TestFailure.dbOpen
        }
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE ai_code_hashes (
            hash TEXT, source TEXT, fileExtension TEXT, fileName TEXT,
            requestId TEXT, conversationId TEXT, timestamp INTEGER,
            model TEXT, createdAt INTEGER
        );
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw TestFailure.dbWrite
        }
        for (timestamp, model) in rows {
            let insert = "INSERT INTO ai_code_hashes (timestamp, model) VALUES (\(timestamp), '\(model)');"
            guard sqlite3_exec(db, insert, nil, nil, nil) == SQLITE_OK else {
                throw TestFailure.dbWrite
            }
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
