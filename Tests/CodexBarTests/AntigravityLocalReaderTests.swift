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
        responseID: String = "resp-1",
        timestampSeconds: UInt64 = 1_781_000_000) -> [UInt8]
    {
        var usage: [UInt8] = []
        usage.append(contentsOf: self.encodeVarint(1, 1132)) // system prompt
        usage.append(contentsOf: self.encodeVarint(2, input))
        usage.append(contentsOf: self.encodeVarint(5, cacheRead))
        usage.append(contentsOf: self.encodeVarint(9, output))
        usage.append(contentsOf: self.encodeVarint(10, reasoning))
        usage.append(contentsOf: self.encodeLengthDelimited(11, Array(responseID.utf8)))

        var genTime: [UInt8] = []
        genTime.append(contentsOf: self.encodeVarint(1, timestampSeconds))
        genTime.append(contentsOf: self.encodeVarint(2, 250_000_000)) // 250ms
        let gen9 = self.encodeLengthDelimited(4, genTime)

        var chatModel: [UInt8] = []
        chatModel.append(contentsOf: self.encodeLengthDelimited(4, usage))
        chatModel.append(contentsOf: self.encodeLengthDelimited(9, gen9))
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
        #expect(AntigravityLocalReader.normalizeModelID("gemini-3-flash-a") == "gemini-3-flash-a")
        #expect(AntigravityLocalReader.normalizeModelID("gemini-3.6-flash") == "gemini-3.6-flash")
        #expect(AntigravityLocalReader.normalizeModelID("gemini-pro-default") == "gemini-pro-default")
        #expect(AntigravityLocalReader.normalizeModelID("gemini-pro-agent") == "gemini-pro-agent")
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

        let trajBlob = Self.buildTrajectoryBlob()
        var trajStmt: OpaquePointer?
        if sqlite3_prepare_v2(
            db,
            "INSERT INTO trajectory_metadata_blob (id, data) VALUES ('main', ?)",
            -1,
            &trajStmt,
            nil) == SQLITE_OK
        {
            _ = trajBlob.withUnsafeBytes { ptr in
                sqlite3_bind_blob(trajStmt, 1, ptr.baseAddress, Int32(trajBlob.count), nil)
            }
            sqlite3_step(trajStmt)
            sqlite3_finalize(trajStmt)
        }

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
