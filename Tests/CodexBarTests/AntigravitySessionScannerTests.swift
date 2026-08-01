import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct AntigravitySessionScannerTests {
    enum SQLiteTestError: Error {
        case open
        case exec(String)
    }

    @Test
    func `scans token usage from conversation database`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.createDatabase(at: env.databaseURL)
        try Self.insertGeneration(
            databaseURL: env.databaseURL,
            meta: GenerationMeta(
                index: 0,
                model: "gemini-3.6-flash",
                responseID: "resp-1",
                timestampMs: Self.ms("2026-07-20T10:00:00.000Z")),
            tokens: Tokens(newlyProcessed: 500, cacheRead: 16000, output: 300, reasoning: 40))
        try Self.insertGeneration(
            databaseURL: env.databaseURL,
            meta: GenerationMeta(
                index: 1,
                model: "gemini-3.6-flash",
                responseID: "resp-2",
                timestampMs: Self.ms("2026-07-20T11:00:00.000Z")),
            tokens: Tokens(newlyProcessed: 100, cacheRead: 0, output: 50, reasoning: 0))

        let now = Date(timeIntervalSince1970: TimeInterval(Self.ms("2026-07-20T12:00:00.000Z")) / 1000)
        let snapshot = AntigravitySessionScanner.scan(
            environment: [AntigravitySessionScanner.homeEnvironmentKey: env.homeURL.path],
            historyDays: 30,
            now: now)

        let report = try #require(snapshot)
        #expect(report.last30DaysTokens == 1132 + 500 + 16000 + 300 + 40 + 1132 + 100 + 50)
        #expect(report.last30DaysRequests == 2)
        #expect(report.daily.count == 1)
        let entry = try #require(report.daily.first)
        #expect(entry.requestCount == 2)
        #expect(entry.inputTokens == 1132 + 500 + 1132 + 100)
        #expect(entry.cacheReadTokens == 16000)
        #expect(entry.outputTokens == 390)
        #expect(entry.modelsUsed == ["gemini-3.6-flash"])
        #expect(entry.modelBreakdowns?.first?.reasoningTokens == 40)
        let expectedCost = (2864.0 * 1.5e-6) + (16000.0 * 0.15e-6) + (390.0 * 7.5e-6)
        #expect(abs((entry.costUSD ?? 0) - expectedCost) < 1e-12)
    }

    @Test
    func `dedupes generations by response id`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.createDatabase(at: env.databaseURL)
        for index in 0..<3 {
            try Self.insertGeneration(
                databaseURL: env.databaseURL,
                meta: GenerationMeta(
                    index: index,
                    model: "gemini-3.6-flash",
                    responseID: "same-response",
                    timestampMs: Self.ms("2026-07-20T10:00:00.000Z")),
                tokens: Tokens(newlyProcessed: 500, cacheRead: 0, output: 300, reasoning: 0))
        }

        let now = Date(timeIntervalSince1970: TimeInterval(Self.ms("2026-07-20T12:00:00.000Z")) / 1000)
        let snapshot = AntigravitySessionScanner.scan(
            environment: [AntigravitySessionScanner.homeEnvironmentKey: env.homeURL.path],
            historyDays: 30,
            now: now)

        #expect(snapshot?.last30DaysRequests == 1)
    }

    @Test
    func `mixed priced and unpriced models withhold day and aggregate cost`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let timestamp = Self.ms("2026-07-20T10:00:00.000Z")
        try Self.insertGeneration(
            databaseURL: env.databaseURL,
            meta: GenerationMeta(
                index: 0,
                model: "gemini-3.6-flash",
                responseID: "priced",
                timestampMs: timestamp),
            tokens: Tokens(newlyProcessed: 10, cacheRead: 0, output: 5, reasoning: 0))
        try Self.insertGeneration(
            databaseURL: env.databaseURL,
            meta: GenerationMeta(
                index: 1,
                model: "unknown-local-model",
                responseID: "unpriced",
                timestampMs: timestamp),
            tokens: Tokens(newlyProcessed: 10, cacheRead: 0, output: 5, reasoning: 0))

        let snapshot = try #require(AntigravitySessionScanner.scan(
            environment: [AntigravitySessionScanner.homeEnvironmentKey: env.homeURL.path],
            historyDays: 30,
            now: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000),
            modelsDevCacheRoot: env.root.appendingPathComponent("empty-pricing", isDirectory: true)))

        #expect(snapshot.daily.first?.costUSD == nil)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.currencyCode == "USD")
        let breakdowns = try #require(snapshot.daily.first?.modelBreakdowns)
        #expect(breakdowns.first { $0.modelName == "gemini-3.6-flash" }?.costUSD != nil)
        #expect(breakdowns.first { $0.modelName == "unknown-local-model" }?.costUSD == nil)
    }

    @Test
    func `scanner propagates a busy database instead of reporting empty history`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)

        var writer: OpaquePointer?
        guard sqlite3_open(env.databaseURL.path, &writer) == SQLITE_OK, let writer else {
            throw SQLiteTestError.open
        }
        defer {
            sqlite3_exec(writer, "ROLLBACK;", nil, nil, nil)
            sqlite3_close(writer)
        }
        guard sqlite3_exec(writer, "BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK else {
            throw SQLiteTestError.exec("begin")
        }

        #expect(throws: AntigravitySessionScanner.ScanError.databaseUnavailable) {
            _ = try AntigravitySessionScanner.scanCancellable(
                environment: [AntigravitySessionScanner.homeEnvironmentKey: env.homeURL.path],
                historyDays: 30,
                now: Date(timeIntervalSince1970: TimeInterval(Self.ms("2026-07-20T12:00:00.000Z")) / 1000))
        }
    }

    @Test
    func `malformed protobuf length does not overflow the field cursor`() throws {
        // A length-delimited field whose declared length is near Int.max must be treated as
        // malformed instead of overflowing `position + count` while slicing.
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)

        var blob: [UInt8] = []
        blob.append(0x12) // field 2, wire type 2 (length-delimited)
        blob.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
        blob.append(contentsOf: [0x00, 0x00])

        var db: OpaquePointer?
        guard sqlite3_open(env.databaseURL.path, &db) == SQLITE_OK, let db else {
            throw SQLiteTestError.open
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO gen_metadata (idx, data) VALUES (1, ?)",
            -1,
            &stmt,
            nil) == SQLITE_OK
        else { throw SQLiteTestError.exec("prepare") }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = blob.withUnsafeBytes { buffer in
            sqlite3_bind_blob(stmt, 1, buffer.baseAddress, Int32(buffer.count), transient)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteTestError.exec("insert") }

        // The scanner must skip the malformed row without trapping on overflow.
        let snapshot = try AntigravitySessionScanner.scanCancellable(
            environment: [AntigravitySessionScanner.homeEnvironmentKey: env.homeURL.path],
            historyDays: 30,
            now: Date(timeIntervalSince1970: TimeInterval(Self.ms("2026-07-20T12:00:00.000Z")) / 1000))
        #expect(snapshot == nil)
    }

    @Test
    func `empty conversations directory yields no snapshot`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let snapshot = AntigravitySessionScanner.scan(
            environment: [AntigravitySessionScanner.homeEnvironmentKey: env.homeURL.path],
            historyDays: 30,
            now: Date())

        #expect(snapshot == nil)
    }

    @Test
    func `database without gen_metadata table is skipped`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        var db: OpaquePointer?
        guard sqlite3_open(env.databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        sqlite3_close(db)

        let snapshot = AntigravitySessionScanner.scan(
            environment: [AntigravitySessionScanner.homeEnvironmentKey: env.homeURL.path],
            historyDays: 30,
            now: Date())

        #expect(snapshot == nil)
    }

    // MARK: - Environment

    private static func makeEnvironment() throws -> (root: URL, homeURL: URL, databaseURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravitySessionScannerTests-\(UUID().uuidString)", isDirectory: true)
        let homeURL = root.appendingPathComponent("antigravity", isDirectory: true)
        let conversationsURL = homeURL.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: conversationsURL, withIntermediateDirectories: true)
        return (root, homeURL, conversationsURL.appendingPathComponent("session-1.db", isDirectory: false))
    }

    private static func createDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }
        try self.exec(db: db, sql: "CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB);")
    }

    struct Tokens {
        /// Fixed system-prompt tokens the scanner adds on top of `newlyProcessed` for billable input.
        var systemPrompt: UInt64 = 1132
        var newlyProcessed: UInt64
        var cacheRead: UInt64
        var output: UInt64
        var reasoning: UInt64
    }

    struct GenerationMeta {
        var index: Int
        var model: String
        var responseID: String?
        var timestampMs: Int64
    }

    private static func insertGeneration(
        databaseURL: URL,
        meta: GenerationMeta,
        tokens: Tokens) throws
    {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }

        let blob = Self.buildGeneration(
            model: meta.model,
            tokens: tokens,
            responseID: meta.responseID,
            timestampMs: meta.timestampMs)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO gen_metadata (idx, data) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK
        else { throw SQLiteTestError.exec("prepare") }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(meta.index))
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = blob.withUnsafeBytes { buffer in
            sqlite3_bind_blob(stmt, 2, buffer.baseAddress, Int32(buffer.count), transient)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteTestError.exec("insert") }
    }

    private static func exec(db: OpaquePointer?, sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw SQLiteTestError.exec(message)
        }
    }

    private static func ms(_ iso: String) -> Int64 {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso) ?? Date(timeIntervalSince1970: 0)
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    // MARK: - Protobuf encoding

    /// Builds a `gen_metadata` blob: `{#1: chatModel}` where chatModel carries `#4: usage`,
    /// `#9: {#4: Timestamp}` and `#19: responseModel`.
    private static func buildGeneration(
        model: String,
        tokens: Tokens,
        responseID: String?,
        timestampMs: Int64) -> [UInt8]
    {
        var usage = self.encVarint(field: 1, value: tokens.systemPrompt)
        usage += self.encVarint(field: 2, value: tokens.newlyProcessed)
        usage += self.encVarint(field: 5, value: tokens.cacheRead)
        usage += self.encVarint(field: 9, value: tokens.output)
        usage += self.encVarint(field: 10, value: tokens.reasoning)
        if let responseID {
            usage += self.encLen(field: 11, payload: Array(responseID.utf8))
        }

        var generation: [UInt8] = []
        generation += self.encLen(field: 4, payload: self.encTimestamp(seconds: timestampMs / 1000, nanos: 0))

        var chatModel = self.encLen(field: 4, payload: usage)
        chatModel += self.encLen(field: 9, payload: generation)
        chatModel += self.encLen(field: 19, payload: Array(model.utf8))

        return self.encLen(field: 1, payload: chatModel)
    }

    private static func encTimestamp(seconds: Int64, nanos: Int64) -> [UInt8] {
        var out = self.encVarint(field: 1, value: UInt64(bitPattern: seconds))
        out += self.encVarint(field: 2, value: UInt64(bitPattern: nanos))
        return out
    }

    private static func encVarint(field: UInt64, value: UInt64) -> [UInt8] {
        self.encodeVarint(field << 3) + self.encodeVarint(value)
    }

    private static func encLen(field: UInt64, payload: [UInt8]) -> [UInt8] {
        self.encodeVarint((field << 3) | 2) + self.encodeVarint(UInt64(payload.count)) + payload
    }

    private static func encodeVarint(_ value: UInt64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        while true {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
            if value == 0 { return out }
        }
    }
}
