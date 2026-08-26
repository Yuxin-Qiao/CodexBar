import Foundation
import Testing
@testable import CodexBarCore
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

/// Tokscale-compatible local readers: Cursor CSV caches
/// (`~/.config/tokscale/cursor-cache/usage*.csv`) and Antigravity session caches
/// (`~/.config/tokscale/antigravity-cache/sessions/*.jsonl`).
/// Header layouts mirror `tokscale/crates/tokscale-core/src/sessions/cursor.rs`:
/// - v1: Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost,Cost to
/// you
/// - v2: Date,Kind,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total
/// Tokens,Cost
/// - v3: Date,Cloud Agent ID,Automation ID,Kind,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache
/// Read,Output Tokens,Total Tokens,Cost
struct CursorAntigravityLocalReaderTests {
    @Test
    func `cursor v1 csv parses token buckets and cost`() throws {
        let csv = """
        Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost,Cost to you
        2026-08-20T10:00:00.000Z,claude-sonnet-4-5,1200,800,400,300,1500,0.012,0
        """
        let url = try Self.writeTemporary(csv, extension: "csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let rows = CursorLocalCSVReader.parseFile(at: url)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.model == "claude-sonnet-4-5")
        #expect(row.input == 800)
        #expect(row.cacheRead == 400)
        #expect(row.cacheWrite == 400)
        #expect(row.output == 300)
        #expect(row.cost == 0.012)
    }

    @Test
    func `cursor v2 csv parses kind rows`() throws {
        let csv = [
            "Date,Kind,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),"
                + "Cache Read,Output Tokens,Total Tokens,Cost",
            "2026-08-20T11:00:00Z,chat,gpt-5.4,on,500,500,0,50,550,0.001",
        ].joined(separator: "\n") + "\n"
        let url = try Self.writeTemporary(csv, extension: "csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let rows = CursorLocalCSVReader.parseFile(at: url)
        let row = try #require(rows.first)
        #expect(row.model == "gpt-5.4")
        #expect(row.input == 500)
        #expect(row.cacheRead == 0)
        #expect(row.cacheWrite == 0)
        #expect(row.output == 50)
    }

    @Test
    func `cursor v3 csv parses cloud agent rows`() throws {
        let csv = [
            "Date,Cloud Agent ID,Automation ID,Kind,Model,Max Mode,"
                + "Input (w/ Cache Write),Input (w/o Cache Write),"
                + "Cache Read,Output Tokens,Total Tokens,Cost",
            "2026-08-20,agent-123,,agent,claude-opus-4-6,off,900,700,200,120,1020,0.05",
        ].joined(separator: "\n") + "\n"
        let url = try Self.writeTemporary(csv, extension: "csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let rows = CursorLocalCSVReader.parseFile(at: url)
        let row = try #require(rows.first)
        #expect(row.model == "claude-opus-4-6")
        #expect(row.input == 700)
        #expect(row.cacheRead == 200)
        #expect(row.cacheWrite == 200)
        #expect(row.output == 120)
        #expect(row.cost == 0.05)
    }

    @Test
    func `cursor csv aggregation groups rows into day entries`() throws {
        let csv = """
        Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost,Cost to you
        2026-08-20T10:00:00.000Z,claude-sonnet-4-5,1200,800,400,300,1500,0.012,0
        2026-08-20T12:00:00.000Z,claude-sonnet-4-5,600,500,100,100,700,0.004,0
        2026-08-21T09:00:00.000Z,gpt-5.4,0,0,0,40,40,0.001,0
        """
        let url = try Self.writeTemporary(csv, extension: "csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let report = CursorLocalCSVReader.makeDailyReport(
            from: CursorLocalCSVReader.parseFile(at: url))
        #expect(report.data.count == 2)
        let first = try #require(report.data.first)
        #expect(first.inputTokens == 1300)
        #expect(first.cacheReadTokens == 500)
        #expect(first.cacheCreationTokens == 500)
        #expect(first.outputTokens == 400)
        #expect(first.requestCount == 2)
        #expect(first.costUSD ?? 0 == 0.016)
        let breakdowns = try #require(first.modelBreakdowns)
        #expect(breakdowns.count == 1)
        #expect(breakdowns.first?.modelName == "claude-sonnet-4-5")
        let summary = try #require(report.summary)
        // The CSV's own Total Tokens column is authoritative when present
        // (1500 + 700 + 40), rather than the recomputed bucket sum.
        #expect(summary.totalTokens == 2240)
    }

    @Test
    func `antigravity cache jsonl aggregates usage with session model fallback`() throws {
        // Derive timestamps from local noon so both events land on the same local day in any TZ.
        let calendar = Calendar.current
        let noon = calendar.date(
            byAdding: .hour, value: 12, to: calendar.startOfDay(for: Date())) ?? Date()
        let firstStamp = Int64(noon.timeIntervalSince1970 * 1000)
        let secondStamp = firstStamp + 3_600_000
        let jsonl = [
            #"{"type":"session_meta","modelId":"test-model-a"}"#,
            #"{"type":"usage","modelId":"test-model-a","input":100,"output":30,"cacheRead":50,"cacheWrite":10,"# +
                #""timestamp":\#(firstStamp)}"#,
            #"{"type":"usage","input":40,"output":10,"cacheRead":0,"cacheWrite":0,"timestamp":\#(secondStamp)}"#,
        ].joined(separator: "\n") + "\n"
        let url = try Self.writeTemporary(jsonl, extension: "jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let entries = AntigravityLocalReader.parseJSONLCache(paths: [url])
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.inputTokens == 140)
        #expect(entry.outputTokens == 40)
        #expect(entry.cacheReadTokens == 50)
        #expect(entry.cacheCreationTokens == 10)
        #expect(entry.requestCount == 2)
        // The second event omits `modelId` and falls back to the session_meta model.
        let breakdowns = try #require(entry.modelBreakdowns)
        #expect(breakdowns.map(\.modelName) == ["test-model-a"])
        #expect(breakdowns.first?.requestCount == 2)
    }

    @Test
    func `protobuf reader decodes varint and string fields accurately`() {
        let blob = Self.buildGenMetadataBlob()
        let chatModel = AntigravityProtoReader.messageField(blob, field: 1)
        #expect(chatModel != nil)
        if let chatModel {
            let model = AntigravityProtoReader.stringField(chatModel, field: 19)
            let label = AntigravityProtoReader.stringField(chatModel, field: 21)
            #expect(model == "gemini-3.6-flash")
            #expect(label == "Gemini 3.6 Flash (High)")

            let usage = AntigravityProtoReader.messageField(chatModel, field: 4)
            #expect(usage != nil)
            if let usage {
                let sys = AntigravityProtoReader.varintField(usage, field: 1)
                let input = AntigravityProtoReader.varintField(usage, field: 2)
                let cacheRead = AntigravityProtoReader.varintField(usage, field: 5)
                let output = AntigravityProtoReader.varintField(usage, field: 9)
                let reasoning = AntigravityProtoReader.varintField(usage, field: 10)
                let respID = AntigravityProtoReader.stringField(usage, field: 11)
                #expect(sys == 1132)
                #expect(input == 500)
                #expect(cacheRead == 100)
                #expect(output == 300)
                #expect(reasoning == 40)
                #expect(respID == "resp-1")
            }
        }
    }

    @Test
    func `model normalization maps known aliases to canonical IDs`() {
        #expect(AntigravityLocalReader.normalizeModelID("gemini-3-flash-a") == "gemini-3.7-flash")
        #expect(AntigravityLocalReader.normalizeModelID("gemini-3.6-flash") == "gemini-3.7-flash")
        #expect(AntigravityLocalReader.normalizeModelID("gemini-pro-default") == "gemini-2.5-pro")
        #expect(AntigravityLocalReader.normalizeModelID("gemini-pro-agent") == "gemini-2.5-pro")
        #expect(AntigravityLocalReader.normalizeModelID("claude-sonnet-4-6") == "claude-sonnet-4-6")
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

        let entries = AntigravityLocalReader.parseCLIDBs(paths: [dbURL])
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.inputTokens == 3264)
        #expect(entry.outputTokens == 600)
        #expect(entry.cacheReadTokens == 200)
        #expect(entry.reasoningTokens == 80)
        #expect(entry.totalTokens == 4144)
        #expect(entry.modelBreakdowns?.count == 1)
        #expect(entry.modelBreakdowns?.first?.modelName == "gemini-3.7-flash")
        #endif
    }

    private static func buildGenMetadataBlob(
        model: String? = "gemini-3.6-flash",
        label: String? = "Gemini 3.6 Flash (High)",
        input: UInt64 = 500,
        output: UInt64 = 300,
        cacheRead: UInt64 = 100,
        reasoning: UInt64 = 40,
        responseID: String = "resp-1") -> [UInt8]
    {
        var usage: [UInt8] = []
        usage.append(contentsOf: self.encodeVarint(1, 1132))
        usage.append(contentsOf: self.encodeVarint(2, input))
        usage.append(contentsOf: self.encodeVarint(5, cacheRead))
        usage.append(contentsOf: self.encodeVarint(9, output))
        usage.append(contentsOf: self.encodeVarint(10, reasoning))
        usage.append(contentsOf: self.encodeLengthDelimited(11, Array(responseID.utf8)))

        var chatModel: [UInt8] = []
        chatModel.append(contentsOf: self.encodeLengthDelimited(4, usage))
        if let model {
            chatModel.append(contentsOf: self.encodeLengthDelimited(19, Array(model.utf8)))
        }
        if let label {
            chatModel.append(contentsOf: self.encodeLengthDelimited(21, Array(label.utf8)))
        }
        return self.encodeLengthDelimited(1, chatModel)
    }

    private static func encodeVarint(_ fieldNumber: Int, _ value: UInt64) -> [UInt8] {
        var result: [UInt8] = []
        var t = UInt64((fieldNumber << 3) | 0)
        while t >= 0x80 {
            result.append(UInt8(t & 0x7F) | 0x80); t >>= 7
        }; result.append(UInt8(t & 0x7F))
        var v = value
        while v >= 0x80 {
            result.append(UInt8(v & 0x7F) | 0x80); v >>= 7
        }; result.append(UInt8(v & 0x7F))
        return result
    }

    private static func encodeLengthDelimited(_ fieldNumber: Int, _ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        var t = UInt64((fieldNumber << 3) | 2)
        while t >= 0x80 {
            result.append(UInt8(t & 0x7F) | 0x80); t >>= 7
        }; result.append(UInt8(t & 0x7F))
        var len = UInt64(bytes.count)
        while len >= 0x80 {
            result.append(UInt8(len & 0x7F) | 0x80); len >>= 7
        }; result.append(UInt8(len & 0x7F))
        result.append(contentsOf: bytes)
        return result
    }

    private static func writeTemporary(_ contents: String, extension fileExtension: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-antigravity-reader-\(UUID().uuidString).\(fileExtension)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
