import Foundation
import Testing
@testable import CodexBarCore

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

struct AntigravityLocalReaderTests {
    private static func encodeVarint(_ fieldNumber: Int, _ value: UInt64) -> [UInt8] {
        var result: [UInt8] = []
        let tag = UInt64((fieldNumber << 3) | 0)
        var t = tag
        while t >= 0x80 {
            result.append(UInt8(t & 0x7F) | 0x80)
            t >>= 7
        }
        result.append(UInt8(t & 0x7F))

        var v = value
        while v >= 0x80 {
            result.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        result.append(UInt8(v & 0x7F))
        return result
    }

    private static func encodeLengthDelimited(_ fieldNumber: Int, _ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        let tag = UInt64((fieldNumber << 3) | 2)
        var t = tag
        while t >= 0x80 {
            result.append(UInt8(t & 0x7F) | 0x80)
            t >>= 7
        }
        result.append(UInt8(t & 0x7F))

        var len = UInt64(bytes.count)
        while len >= 0x80 {
            result.append(UInt8(len & 0x7F) | 0x80)
            len >>= 7
        }
        result.append(UInt8(len & 0x7F))
        result.append(contentsOf: bytes)
        return result
    }

    private static func buildGenMetadataBlob(
        model: String? = "gemini-3.6-flash",
        label: String? = "Gemini 3.6 Flash (High)",
        input: UInt64 = 500,
        output: UInt64 = 300,
        cacheRead: UInt64 = 100,
        reasoning: UInt64 = 40,
        responseID: String? = "resp-1",
        timestampSeconds: UInt64? = 1_781_000_000) -> [UInt8]
    {
        var usage: [UInt8] = []
        usage.append(contentsOf: self.encodeVarint(1, 1132)) // system prompt
        usage.append(contentsOf: self.encodeVarint(2, input))
        usage.append(contentsOf: self.encodeVarint(5, cacheRead))
        usage.append(contentsOf: self.encodeVarint(9, output))
        usage.append(contentsOf: self.encodeVarint(10, reasoning))
        if let responseID {
            usage.append(contentsOf: self.encodeLengthDelimited(11, Array(responseID.utf8)))
        }

        var chatModel: [UInt8] = []
        chatModel.append(contentsOf: self.encodeLengthDelimited(4, usage))
        if let timestampSeconds {
            var genTime: [UInt8] = []
            genTime.append(contentsOf: self.encodeVarint(1, timestampSeconds))
            genTime.append(contentsOf: self.encodeVarint(2, 250_000_000)) // 250ms
            let gen9 = self.encodeLengthDelimited(4, genTime)
            chatModel.append(contentsOf: self.encodeLengthDelimited(9, gen9))
        }
        if let model {
            chatModel.append(contentsOf: self.encodeLengthDelimited(19, Array(model.utf8)))
        }
        if let label {
            chatModel.append(contentsOf: self.encodeLengthDelimited(21, Array(label.utf8)))
        }

        return self.encodeLengthDelimited(1, chatModel)
    }

    private static func buildTrajectoryBlob(timestampSeconds: UInt64 = 1_780_000_000) -> [UInt8] {
        var timeMsg: [UInt8] = []
        timeMsg.append(contentsOf: self.encodeVarint(1, timestampSeconds))
        timeMsg.append(contentsOf: self.encodeVarint(2, 0))
        let timeField2 = self.encodeLengthDelimited(2, timeMsg)

        var root: [UInt8] = []
        root.append(contentsOf: timeField2)
        return root
    }

    @Test
    func `protobuf reader decodes varint and string fields accurately`() {
        let blob = Self.buildGenMetadataBlob()
        let turn = AntigravityProtoReader.parseTurn(blob)
        #expect(turn != nil)
        if let turn {
            #expect(turn.model == "gemini-3.6-flash")
            #expect(turn.label == "Gemini 3.6 Flash (High)")
            #expect(turn.timestampMs == 1_781_000_000_250)

            let usage = turn.usage
            #expect(usage != nil)
            if let usage {
                #expect(usage.systemPrompt == 1132)
                #expect(usage.newInput == 500)
                #expect(usage.cacheRead == 100)
                #expect(usage.output == 300)
                #expect(usage.reasoning == 40)
                #expect(usage.responseID == "resp-1")
            }
        }
    }

    @Test
    func `protobuf reader handles malformed and truncated buffers safely`() {
        var emptyReader = AntigravityProtoReader(bytes: [])
        #expect(emptyReader.nextField() == nil)

        // Truncated length-delimited wire
        let truncatedLength: [UInt8] = [(1 << 3) | 2, 0x80]
        var truncReader = AntigravityProtoReader(bytes: truncatedLength)
        #expect(truncReader.nextField() == nil)
        #expect(truncReader.isMalformed)

        // Invalid 10th varint byte (continuation bit set)
        let invalidVarint: [UInt8] = Array(repeating: 0x80, count: 10)
        var varintReader = AntigravityProtoReader(bytes: invalidVarint)
        #expect(varintReader.readVarint() == nil)
        #expect(varintReader.isMalformed)

        // Invalid nanos in timestamp (> 999,999,999)
        let invalidNanosMsg: [UInt8] = Self.encodeVarint(1, 1_780_000_000) + Self.encodeVarint(2, 1_000_000_000)
        #expect(AntigravityProtoReader.protoTimestampMs(invalidNanosMsg) == nil)
    }

    @Test
    func `model normalization maps known aliases to canonical IDs`() {
        #expect(AntigravityLocalReader.normalizeModelID("gemini-3-flash-a") == "gemini-3-flash-a")
        #expect(AntigravityLocalReader.normalizeModelID("gemini-3.6-flash") == "gemini-3.6-flash")
        #expect(AntigravityLocalReader.normalizeModelID("gemini-pro-default") == "gemini-pro-default")
        #expect(AntigravityLocalReader.normalizeModelID("gemini-pro-agent") == "gemini-pro-agent")
        #expect(AntigravityLocalReader.normalizeModelID("claude-sonnet-4-6") == "claude-sonnet-4-6")
        #expect(AntigravityLocalReader.normalizeModelID("") == "unknown")
        #expect(AntigravityLocalReader.normalizeModelID("   ") == "unknown")
    }

    @Test
    func `parses sqlite database with gen_metadata and trajectory_metadata_blob`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbURL = tmpDir.appendingPathComponent("test-session.db")
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db
        else {
            Issue.record("Failed to create sqlite db")
            return
        }

        sqlite3_exec(db, "CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB, size INTEGER);", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE trajectory_metadata_blob (id TEXT PRIMARY KEY, data BLOB);", nil, nil, nil)

        let blob1 = Self.buildGenMetadataBlob(
            model: "gemini-3.6-flash",
            label: "Gemini 3.6 Flash (High)",
            responseID: "resp-1")
        let blob2 = Self.buildGenMetadataBlob(model: nil, label: "Gemini 3.6 Flash (High)", responseID: "resp-2")

        for (idx, blob) in [(0, blob1), (1, blob2)] {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "INSERT INTO gen_metadata (idx, data, size) VALUES (?, ?, ?)", -1, &stmt, nil) ==
                SQLITE_OK
            {
                sqlite3_bind_int(stmt, 1, Int32(idx))
                _ = blob.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(blob.count), nil)
                }
                sqlite3_bind_int(stmt, 3, Int32(blob.count))
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
        sqlite3_close(db)

        let outcome = AntigravityLocalReader.parseCLIDBsWithStatus(paths: [dbURL])
        #expect(outcome.isComplete == true)
        #expect(outcome.entries.count == 1)
        let entry = try #require(outcome.entries.first)
        #expect(entry.inputTokens == 3264) // (1132+500) * 2
        #expect(entry.outputTokens == 600)
        #expect(entry.cacheReadTokens == 200)
        #expect(entry.reasoningTokens == 80)
        #expect(entry.totalTokens == 4144)
        #expect(entry.modelBreakdowns?.count == 1)
        #expect(entry.modelBreakdowns?.first?.modelName == "gemini-3.6-flash")
        #endif
    }

    @Test
    func `production end-to-end token snapshot via CostUsageFetcher`() async throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let convDir = tmp.appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)

        let dbURL = convDir.appendingPathComponent("session-prod.db")
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db
        else {
            Issue.record("Failed to create sqlite db")
            return
        }
        sqlite3_exec(db, "CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB, size INTEGER);", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE trajectory_metadata_blob (id TEXT PRIMARY KEY, data BLOB);", nil, nil, nil)

        let blob = Self.buildGenMetadataBlob(
            model: "gemini-2.5-pro",
            label: "Gemini 2.5 Pro",
            input: 1000,
            output: 200,
            cacheRead: 50,
            reasoning: 20,
            responseID: "r-prod",
            timestampSeconds: 1_781_000_000)

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO gen_metadata (idx, data, size) VALUES (0, ?, ?)", -1, &stmt, nil) ==
            SQLITE_OK
        {
            _ = blob.withUnsafeBytes { ptr in sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(blob.count), nil) }
            sqlite3_bind_int(stmt, 2, Int32(blob.count))
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        sqlite3_close(db)

        let now = Date(timeIntervalSince1970: 1_781_000_000)
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .antigravity,
            environment: ["HOME": tmp.path],
            now: now,
            historyDays: 30)

        #expect(snapshot.sessionTokens == 2402)
        #expect(snapshot.last30DaysTokens == 2402)
        #expect(snapshot.historyCoverageIsEstablished == true)
        #expect(snapshot.daily.count == 1)
        #expect(snapshot.daily.first?.modelBreakdowns?.first?.modelName == "gemini-2.5-pro")
        #endif
    }

    @Test
    func `live WAL fixture snapshot consistency and sidecar preservation`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("live-wal.db")
        let walURL = tmp.appendingPathComponent("live-wal.db-wal")
        let shmURL = tmp.appendingPathComponent("live-wal.db-shm")

        var writeDB: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &writeDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let writeDB
        else {
            Issue.record("Failed to create live WAL db")
            return
        }
        sqlite3_exec(writeDB, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(
            writeDB,
            "CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB, size INTEGER);",
            nil,
            nil,
            nil)

        let blob = Self.buildGenMetadataBlob(responseID: "live-wal-r1")
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(writeDB, "INSERT INTO gen_metadata (idx, data, size) VALUES (0, ?, ?)", -1, &stmt, nil) ==
            SQLITE_OK
        {
            _ = blob.withUnsafeBytes { ptr in sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(blob.count), nil) }
            sqlite3_bind_int(stmt, 2, Int32(blob.count))
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }

        // Keep writeDB open to simulate a live process holding WAL lock and sidecars
        let entries = AntigravityLocalReader.parseCLIDBs(paths: [dbURL])
        #expect(entries.count == 1)
        #expect(entries.first?.totalTokens == 2072)

        #expect(FileManager.default.fileExists(atPath: dbURL.path))
        #expect(FileManager.default.fileExists(atPath: walURL.path))
        #expect(FileManager.default.fileExists(atPath: shmURL.path))

        sqlite3_close(writeDB)
        #endif
    }

    @Test
    func `multi-database request count aggregation across shared model`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL1 = tmp.appendingPathComponent("db1.db")
        let dbURL2 = tmp.appendingPathComponent("db2.db")

        for (dbURL, prefix) in [(dbURL1, "d1"), (dbURL2, "d2")] {
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
                  let db
            else {
                Issue.record("Failed to create db")
                return
            }
            sqlite3_exec(
                db,
                "CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB, size INTEGER);",
                nil,
                nil,
                nil)
            for i in 0..<2 {
                let blob = Self.buildGenMetadataBlob(
                    model: "gemini-2.5-pro",
                    label: "Gemini 2.5 Pro",
                    input: 500,
                    output: 100,
                    cacheRead: 0,
                    reasoning: 0,
                    responseID: "\(prefix)-turn-\(i)",
                    timestampSeconds: 1_781_000_000)
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(
                    db,
                    "INSERT INTO gen_metadata (idx, data, size) VALUES (?, ?, ?)",
                    -1,
                    &stmt,
                    nil) == SQLITE_OK
                {
                    sqlite3_bind_int(stmt, 1, Int32(i))
                    _ = blob
                        .withUnsafeBytes { ptr in sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(blob.count), nil) }
                    sqlite3_bind_int(stmt, 3, Int32(blob.count))
                    sqlite3_step(stmt)
                    sqlite3_finalize(stmt)
                }
            }
            sqlite3_close(db)
        }

        let outcome = AntigravityLocalReader.parseCLIDBsWithStatus(paths: [dbURL1, dbURL2])
        #expect(outcome.isComplete)
        #expect(outcome.entries.count == 1)
        let entry = try #require(outcome.entries.first)
        #expect(entry.requestCount == 4)
        let breakdown = try #require(entry.modelBreakdowns?.first)
        #expect(breakdown.modelName == "gemini-2.5-pro")
        #expect(breakdown.requestCount == 4)
        #endif
    }

    @Test
    func `duplicate and missing response IDs`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("dup.db")
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db
        else {
            Issue.record("Failed to create db")
            return
        }
        sqlite3_exec(db, "CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB, size INTEGER);", nil, nil, nil)

        let blob1 = Self.buildGenMetadataBlob(responseID: "dup-id")
        let blob2 = Self.buildGenMetadataBlob(responseID: "dup-id") // duplicate ID: should be skipped
        let blob3 = Self.buildGenMetadataBlob(responseID: nil) // missing ID 1: should be counted
        let blob4 = Self.buildGenMetadataBlob(responseID: nil) // missing ID 2: should be counted

        for (idx, blob) in [(0, blob1), (1, blob2), (2, blob3), (3, blob4)] {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "INSERT INTO gen_metadata (idx, data, size) VALUES (?, ?, ?)", -1, &stmt, nil) ==
                SQLITE_OK
            {
                sqlite3_bind_int(stmt, 1, Int32(idx))
                _ = blob.withUnsafeBytes { ptr in sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(blob.count), nil) }
                sqlite3_bind_int(stmt, 3, Int32(blob.count))
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
        sqlite3_close(db)

        let entries = AntigravityLocalReader.parseCLIDBs(paths: [dbURL])
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.requestCount == 3)
        #endif
    }

    @Test
    func `missing turn timestamp marks scan incomplete`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("no-timestamp.db")
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db
        else {
            Issue.record("Failed to create db")
            return
        }
        sqlite3_exec(db, "CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB, size INTEGER);", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE trajectory_metadata_blob (id TEXT PRIMARY KEY, data BLOB);", nil, nil, nil)

        // Turn without timestampSeconds
        let blob = Self.buildGenMetadataBlob(responseID: "no-time", timestampSeconds: nil)
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO gen_metadata (idx, data, size) VALUES (0, ?, ?)", -1, &stmt, nil) ==
            SQLITE_OK
        {
            _ = blob.withUnsafeBytes { ptr in sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(blob.count), nil) }
            sqlite3_bind_int(stmt, 2, Int32(blob.count))
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        sqlite3_close(db)

        let outcome = AntigravityLocalReader.parseCLIDBsWithStatus(paths: [dbURL])
        #expect(outcome.isComplete == false)
        #expect(outcome.entries.isEmpty)
        #endif
    }

    @Test
    func `resource limits mark scan incomplete`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("oversized.db")
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db
        else {
            Issue.record("Failed to create db")
            return
        }
        sqlite3_exec(db, "CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB, size INTEGER);", nil, nil, nil)

        // Insert a corrupt/empty blob with size indicator
        sqlite3_exec(db, "INSERT INTO gen_metadata (idx, data, size) VALUES (0, X'', 0);", nil, nil, nil)
        sqlite3_close(db)

        let outcome = AntigravityLocalReader.parseCLIDBsWithStatus(paths: [dbURL])
        #expect(outcome.isComplete == false)
        #endif
    }

    @Test
    func `consumer overflow safety across days`() {
        let day1 = CostUsageDailyReport.Entry(
            date: "2026-08-20",
            inputTokens: Int.max - 1,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            reasoningTokens: 0,
            totalTokens: Int.max - 1,
            requestCount: 1,
            costUSD: nil,
            modelsUsed: ["gemini-pro"],
            modelBreakdowns: nil)
        let day2 = CostUsageDailyReport.Entry(
            date: "2026-08-21",
            inputTokens: 2,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            reasoningTokens: 0,
            totalTokens: 2,
            requestCount: 1,
            costUSD: nil,
            modelsUsed: ["gemini-pro"],
            modelBreakdowns: nil)

        let report = CostUsageDailyReport(data: [day1, day2], summary: nil)
        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: report,
            now: Date(),
            historyDays: 30)

        // Verifies summary reduction does not trap when summing (Int.max - 1) + 2
        let summary = snapshot.summary(forLastDays: 30)
        #expect(summary.totalTokens == nil)
    }

    @Test
    func `parses tokscale jsonl session cache`() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let jsonlURL = tmpDir.appendingPathComponent("tokscale-sess.jsonl")
        let line1 = "{\"type\":\"session_meta\",\"sessionId\":\"tokscale-sess\","
            + "\"modelId\":\"gemini-2.5-pro\"}"
        let line2 = "{\"type\":\"usage\",\"sessionId\":\"tokscale-sess\",\"timestamp\":1781000000000.0,"
            + "\"modelId\":\"gemini-2.5-pro\",\"input\":1000,\"output\":200,\"cacheRead\":50,"
            + "\"reasoning\":20,\"responseId\":\"r-1\"}"
        let content = [line1, line2].joined(separator: "\n")
        try content.write(to: jsonlURL, atomically: true, encoding: .utf8)

        let entries = AntigravityLocalReader.parseJSONLCache(paths: [jsonlURL])
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.inputTokens == 1000)
        #expect(entry.outputTokens == 200)
        #expect(entry.cacheReadTokens == 50)
        #expect(entry.reasoningTokens == 20)
        #expect(entry.totalTokens == 1270)
        #expect(entry.modelBreakdowns?.first?.modelName == "gemini-2.5-pro")
    }

    @Test
    func `cliDBPaths discovers conversations directories`() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let conv1 = tmp.appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true)
        let conv2 = tmp.appendingPathComponent(".gemini/antigravity-cli/conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: conv1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: conv2, withIntermediateDirectories: true)

        FileManager.default.createFile(atPath: conv1.appendingPathComponent("1.db").path, contents: Data())
        FileManager.default.createFile(atPath: conv2.appendingPathComponent("2.db").path, contents: Data())
        FileManager.default.createFile(atPath: conv2.appendingPathComponent("2.db-wal").path, contents: Data())

        let paths = AntigravityLocalReader.cliDBPaths(home: tmp)
        #expect(paths.count == 2)
        #expect(paths.allSatisfy { $0.pathExtension == "db" })
    }
}
