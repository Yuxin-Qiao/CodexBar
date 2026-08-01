import CodexBarCore
import Foundation
import Testing

struct GeminiSessionScannerTests {
    @Test
    func `scanner aggregates chat recordings across projects layouts and models`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsA = try Self.makeChatsDir(root, "hash-a")
        let chatsB = try Self.makeChatsDir(root, "hash-b")

        try Self.write(Self.chatRecording(messages: [
            #"{"id":"m1","timestamp":"2026-07-10T09:00:00Z","type":"user"}"#,
            Self.modelTurn(
                id: "m2",
                timestamp: "2026-07-10T09:01:00Z",
                tokens: #"{"input":100,"output":20,"cached":10,"thoughts":5,"tool":3,"total":138}"#),
            Self.modelTurn(
                id: "m3",
                timestamp: "2026-07-10T09:02:00Z",
                tokens: #"{"input":15,"output":20,"cached":5,"thoughts":2,"tool":0,"total":37}"#),
        ]), to: chatsA.appendingPathComponent("session-one.json"))
        try Self.write(Self.chatRecording(messages: [
            Self.modelTurn(
                id: "m1",
                timestamp: "2026-07-11T10:00:00Z",
                model: "gemini-2.0-flash",
                tokens: #"{"input":8,"output":9,"total":17}"#),
        ]), to: chatsB.appendingPathComponent("session-two.json"))
        // Legacy layout: `session-` prefix accepted anywhere under `tmp`.
        try Self.write(Self.chatRecording(messages: [
            Self.modelTurn(
                id: "m1",
                timestamp: "2026-07-11T11:00:00Z",
                model: "gemini-2.0-flash",
                tokens: #"{"input":1,"output":2,"total":3}"#),
        ]), to: root.appendingPathComponent("tmp/session-legacy.json"))
        // Decoys: wrong extension, and a `.json` outside the expected layouts.
        try Self.write("not json", to: chatsB.appendingPathComponent("notes.txt"))
        try Self.write(
            #"{"messages":[{"id":"x","model":"gemini-2.0-flash","tokens":{"input":99,"output":99}}]}"#,
            to: root.appendingPathComponent("tmp/hash-b/other.json"))

        let snapshot = try #require(Self.scan(root: root, now: Self.date("2026-07-12T12:00:00Z")))

        #expect(snapshot.currencyCode == "XXX")
        #expect(snapshot.historyLabel == "Gemini CLI")
        #expect(snapshot.historyDays == 30)
        #expect(snapshot.last30DaysTokens == 195)
        #expect(snapshot.last30DaysRequests == 4)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.sessionTokens == nil)
        #expect(snapshot.daily.map(\.date) == ["2026-07-10", "2026-07-11"])

        let first = snapshot.daily[0]
        #expect(first.inputTokens == 113)
        #expect(first.outputTokens == 47)
        #expect(first.cacheReadTokens == 15)
        #expect(first.cacheCreationTokens == nil)
        #expect(first.totalTokens == 175)
        #expect(first.requestCount == 2)
        #expect(first.costUSD == nil)
        #expect(first.modelsUsed == ["gemini-2.5-pro"])
        let firstBreakdown = try #require(first.modelBreakdowns?.first)
        #expect(firstBreakdown.modelName == "gemini-2.5-pro")
        #expect(firstBreakdown.inputTokens == 113)
        #expect(firstBreakdown.outputTokens == 47)
        #expect(firstBreakdown.cacheReadTokens == 15)
        #expect(firstBreakdown.cacheCreationTokens == nil)
        // `thoughts` stays folded into billing output and is also surfaced as the reasoning bucket.
        #expect(firstBreakdown.reasoningTokens == 7)
        #expect(firstBreakdown.totalTokens == 175)
        #expect(firstBreakdown.requestCount == 2)
        #expect(firstBreakdown.costUSD == nil)

        let second = snapshot.daily[1]
        #expect(second.inputTokens == 9)
        #expect(second.outputTokens == 11)
        #expect(second.cacheReadTokens == 0)
        #expect(second.totalTokens == 20)
        #expect(second.requestCount == 2)
        #expect(second.modelsUsed == ["gemini-2.0-flash"])
        #expect(second.modelBreakdowns?.first?.reasoningTokens == nil)
    }

    @Test
    func `scanner buckets usage by local day across midnight`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = try Self.makeChatsDir(root, "hash-a")
        try Self.write(Self.chatRecording(messages: [
            // 23:30 at GMT+8 on 2026-07-10.
            Self.modelTurn(id: "m1", timestamp: "2026-07-10T15:30:00Z", tokens: #"{"input":1,"output":2}"#),
            // 00:30 at GMT+8 on 2026-07-11.
            Self.modelTurn(id: "m2", timestamp: "2026-07-10T16:30:00Z", tokens: #"{"input":3,"output":4}"#),
        ]), to: chats.appendingPathComponent("session-one.json"))

        let snapshot = try #require(Self.scan(
            root: root,
            now: Self.date("2026-07-12T12:00:00Z"),
            calendar: Self.gmtPlus8Calendar))

        #expect(snapshot.daily.map(\.date) == ["2026-07-10", "2026-07-11"])
        #expect(snapshot.daily.map(\.requestCount) == [1, 1])
        #expect(snapshot.daily.map(\.totalTokens) == [3, 7])
    }

    @Test
    func `scanner prefilters by file mtime and falls back to mtime for missing timestamps`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = try Self.makeChatsDir(root, "hash-a")

        // mtime older than the window: skipped without parsing, even for in-window timestamps.
        let oldFile = chats.appendingPathComponent("session-old.json")
        try Self.write(Self.chatRecording(messages: [
            Self.modelTurn(
                id: "m1",
                timestamp: "2026-07-12T09:00:00Z",
                tokens: #"{"input":100,"output":100}"#),
        ]), to: oldFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Self.date("2026-06-02T12:00:00Z")],
            ofItemAtPath: oldFile.path)
        // Fresh mtime but a record older than the window: dropped by the day filter.
        try Self.write(Self.chatRecording(messages: [
            Self.modelTurn(
                id: "m1",
                timestamp: "2026-06-02T09:00:00Z",
                tokens: #"{"input":200,"output":200}"#),
        ]), to: chats.appendingPathComponent("session-stale.json"))
        // No timestamp at all: bucketed by the file mtime, pinned inside the window here.
        let fallbackFile = chats.appendingPathComponent("session-fallback.json")
        try Self.write(Self.chatRecording(messages: [
            #"{"id":"m1","type":"gemini","model":"gemini-2.5-pro","tokens":{"input":5,"output":6}}"#,
        ]), to: fallbackFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Self.date("2026-07-12T09:00:00Z")],
            ofItemAtPath: fallbackFile.path)

        let snapshot = try #require(Self.scan(root: root, now: Self.date("2026-07-12T12:00:00Z")))

        #expect(snapshot.daily.map(\.date) == ["2026-07-12"])
        #expect(snapshot.last30DaysRequests == 1)
        #expect(snapshot.last30DaysTokens == 11)
        #expect(snapshot.daily.first?.inputTokens == 5)
        #expect(snapshot.daily.first?.outputTokens == 6)
    }

    @Test
    func `scanner skips corrupt files records and stream lines`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = try Self.makeChatsDir(root, "hash-a")

        try Self.write("this is not json", to: chats.appendingPathComponent("session-garbage.json"))
        try Self.write(#"{"foo":1}"#, to: chats.appendingPathComponent("session-shape.json"))
        try Self.write(Self.chatRecording(messages: [
            #"{"id":"m1","timestamp":"2026-07-10T09:00:00Z","type":"gemini","tokens":{"input":1,"output":1}}"#,
            #"{"id":"m2","timestamp":"2026-07-10T09:01:00Z","type":"gemini","model":"gemini-2.5-pro"}"#,
        ]), to: chats.appendingPathComponent("session-incomplete.json"))
        try Self.write("", to: chats.appendingPathComponent("session-empty.jsonl"))
        try Self.write([
            "not json at all",
            #"{"type":"init","model":"gemini-2.5-pro","session_id":"s1"}"#,
            #"{"type":"gemini","id":"x1","timestamp":"2026-07-10T09:00:00.000Z","tokens":{"input":10,"output":5}}"#,
        ].joined(separator: "\n"), to: chats.appendingPathComponent("session-mixed.jsonl"))

        let snapshot = try #require(Self.scan(root: root, now: Self.date("2026-07-12T12:00:00Z")))

        #expect(snapshot.daily.map(\.date) == ["2026-07-10"])
        #expect(snapshot.last30DaysRequests == 1)
        #expect(snapshot.last30DaysTokens == 15)
        #expect(snapshot.daily.first?.modelsUsed == ["gemini-2.5-pro"])
    }

    @Test
    func `scanner skips negative token values and overflowing accumulations`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = try Self.makeChatsDir(root, "hash-a")
        try Self.write(Self.chatRecording(messages: [
            Self.modelTurn(
                id: "m1",
                timestamp: "2026-07-10T09:00:00Z",
                tokens: #"{"input":-1,"output":2,"total":1}"#),
            Self.modelTurn(
                id: "m2",
                timestamp: "2026-07-10T09:01:00Z",
                tokens: #"{"input":1,"output":2,"total":-3}"#),
            Self.modelTurn(
                id: "m3",
                timestamp: "2026-07-10T09:02:00Z",
                tokens: #"{"input":9223372036854775807,"output":0}"#),
            Self.modelTurn(
                id: "m4",
                timestamp: "2026-07-10T09:03:00Z",
                tokens: #"{"input":10,"output":0}"#),
        ]), to: chats.appendingPathComponent("session-one.json"))

        let snapshot = try #require(Self.scan(root: root, now: Self.date("2026-07-12T12:00:00Z")))

        // Only the Int.max record survives; the follow-up record overflows the accumulator and
        // is dropped without poisoning the bucket.
        #expect(snapshot.last30DaysRequests == 1)
        #expect(snapshot.last30DaysTokens == Int.max)
        #expect(snapshot.daily.first?.inputTokens == Int.max)
    }

    @Test
    func `scanner parses chat streams with model hints and replaces duplicate message ids`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = try Self.makeChatsDir(root, "hash-a")
        try Self.write([
            // swiftlint:disable:next line_length
            #"{"sessionId":"s1","projectHash":"hash-a","startTime":"2026-07-10T00:00:00.000Z","lastUpdated":"2026-07-10T00:01:00.000Z"}"#,
            #"{"type":"init","model":"gemini-2.5-pro","session_id":"s1"}"#,
            // swiftlint:disable:next line_length
            #"{"id":"m1","timestamp":"2026-07-10T09:00:00.000Z","type":"gemini","tokens":{"input":10,"output":1,"total":11}}"#,
            // swiftlint:disable:next line_length
            #"{"id":"m1","timestamp":"2026-07-10T09:01:00.000Z","type":"gemini","tokens":{"input":20,"output":2,"cached":5,"thoughts":3,"total":25}}"#,
            #"{"timestamp":"2026-07-10T09:02:00.000Z","type":"gemini","tokens":{"input":7,"output":8}}"#,
            #"{"timestamp":"2026-07-10T09:03:00.000Z","type":"user"}"#,
        ].joined(separator: "\n"), to: chats.appendingPathComponent("session-stream.jsonl"))

        let snapshot = try #require(Self.scan(root: root, now: Self.date("2026-07-12T12:00:00Z")))

        // The second "m1" line replaces the first (cache-inclusive input 20 normalizes to 15,
        // thoughts fold into output), and the id-less line inherits the `init` model.
        #expect(snapshot.daily.map(\.date) == ["2026-07-10"])
        #expect(snapshot.last30DaysRequests == 2)
        #expect(snapshot.last30DaysTokens == 40)
        let entry = snapshot.daily[0]
        #expect(entry.inputTokens == 22)
        #expect(entry.outputTokens == 13)
        #expect(entry.cacheReadTokens == 5)
        #expect(entry.modelsUsed == ["gemini-2.5-pro"])
        #expect(entry.modelBreakdowns?.first?.reasoningTokens == 3)
    }

    @Test
    func `scanner honors GEMINI_CLI_HOME override and returns nil for empty directories`() throws {
        let emptyRoot = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: emptyRoot) }

        #expect(Self.scan(root: emptyRoot, now: Self.date("2026-07-12T12:00:00Z")) == nil)

        let tmp = emptyRoot.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        #expect(Self.scan(root: emptyRoot, now: Self.date("2026-07-12T12:00:00Z")) == nil)

        let fixtureRoot = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let chats = try Self.makeChatsDir(fixtureRoot, "hash-a")
        try Self.write(Self.chatRecording(messages: [
            Self.modelTurn(id: "m1", timestamp: "2026-07-10T09:00:00Z", tokens: #"{"input":1,"output":2}"#),
        ]), to: chats.appendingPathComponent("session-one.json"))

        let snapshot = try #require(Self.scan(root: fixtureRoot, now: Self.date("2026-07-12T12:00:00Z")))
        #expect(snapshot.last30DaysTokens == 3)
        #expect(snapshot.historyLabel == "Gemini CLI")
    }

    @Test
    func `scanner reports oversized eligible transcripts as incomplete`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = try Self.makeChatsDir(root, "hash-a")
        let transcript = chats.appendingPathComponent("oversized.jsonl")
        try Data(repeating: 0x20, count: GeminiSessionScanner.maximumFileBytes + 1)
            .write(to: transcript)

        #expect(throws: GeminiSessionScanner.ScanError.historyLimitExceeded) {
            try GeminiSessionScanner.scanCancellable(
                environment: [GeminiSessionScanner.cliHomeEnvironmentKey: root.path],
                historyDays: 30,
                now: Self.date("2026-07-12T12:00:00Z"),
                calendar: Self.utcCalendar)
        }
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
        GeminiSessionScanner.scan(
            environment: [GeminiSessionScanner.cliHomeEnvironmentKey: root.path],
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

    private static func makeChatsDir(_ root: URL, _ projectHash: String) throws -> URL {
        let dir = root.appendingPathComponent("tmp/\(projectHash)/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func chatRecording(messages: [String]) -> String {
        """
        {"sessionId":"ses","projectHash":"hash","startTime":"2026-07-10T09:00:00Z",\
        "lastUpdated":"2026-07-10T09:05:00Z","messages":[\(messages.joined(separator: ","))]}
        """
    }

    private static func modelTurn(
        id: String,
        timestamp: String,
        model: String = "gemini-2.5-pro",
        tokens: String) -> String
    {
        #"{"id":"\#(id)","timestamp":"\#(timestamp)","type":"gemini","model":"\#(model)","tokens":\#(tokens)}"#
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
