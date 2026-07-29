import CodexBarCore
import Foundation
import Testing

struct QwenCodeSessionScannerTests {
    @Test
    func `scanner reads Qwen Code assistant usage and preserves billing owner`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QwenCodeSessionScannerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = root
            .appendingPathComponent("projects/project-a/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let assistantOne = #"{"type":"assistant","model":"qwen3-coder-plus","# +
            #""timestamp":"2026-07-28T08:01:00Z","usageMetadata":{"promptTokenCount":100,"# +
            #""candidatesTokenCount":30,"thoughtsTokenCount":20,"cachedContentTokenCount":200}}"#
        let assistantTwo = #"{"type":"assistant","model":"qwen3-coder-plus","# +
            #""timestamp":"2026-07-28T08:02:00Z","usageMetadata":{"promptTokenCount":10,"# +
            #""candidatesTokenCount":5,"thoughtsTokenCount":2,"cachedContentTokenCount":20}}"#
        let jsonl = [
            #"{"type":"user","timestamp":"2026-07-28T08:00:00Z"}"#,
            assistantOne,
            assistantTwo,
        ].joined(separator: "\n")
        try Data(jsonl.utf8).write(to: chats.appendingPathComponent("session.jsonl"))

        let snapshot = try #require(QwenCodeSessionScanner.scan(
            environment: [QwenCodeSessionScanner.homeEnvironmentKey: root.path],
            historyDays: 30,
            now: Date(timeIntervalSince1970: 1_785_283_200),
            calendar: Self.calendar,
            modelsDevCacheRoot: root.appendingPathComponent("pricing-cache", isDirectory: true)))

        #expect(snapshot.historyLabel == "Qwen Code CLI")
        #expect(snapshot.last30DaysRequests == 2)
        #expect(snapshot.last30DaysTokens == 387)
        let entry = try #require(snapshot.daily.first)
        #expect(entry.inputTokens == 110)
        #expect(entry.outputTokens == 57)
        #expect(entry.cacheReadTokens == 220)
        #expect(entry.totalTokens == 387)
        let model = try #require(entry.modelBreakdowns?.first)
        #expect(model.modelName == "qwen3-coder-plus")
        #expect(model.billingProviderID == UsageProvider.qwencloud.rawValue)
        #expect(model.reasoningTokens == 22)
    }

    @Test
    func `scanner ignores other layouts and cooperatively cancels`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QwenCodeSessionScannerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = root.appendingPathComponent("projects/project-a/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let realEntry = #"{"type":"assistant","model":"qwen3-coder","# +
            #""timestamp":"2026-07-28T08:01:00Z","usageMetadata":{"promptTokenCount":1,"# +
            #""candidatesTokenCount":1}}"#
        try Data(realEntry.utf8).write(to: chats.appendingPathComponent("session.jsonl"))
        let decoy = root.appendingPathComponent("projects/project-a/other", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        let decoyEntry = #"{"type":"assistant","model":"decoy","# +
            #""timestamp":"2026-07-28T08:01:00Z","usageMetadata":{"promptTokenCount":999,"# +
            #""candidatesTokenCount":999}}"#
        try Data(decoyEntry.utf8).write(to: decoy.appendingPathComponent("session.jsonl"))

        var checks = 0
        #expect(throws: CancellationError.self) {
            _ = try QwenCodeSessionScanner.scanCancellable(
                environment: [QwenCodeSessionScanner.homeEnvironmentKey: root.path],
                historyDays: 30,
                now: Date(timeIntervalSince1970: 1_785_283_200),
                calendar: Self.calendar,
                checkCancellation: {
                    checks += 1
                    if checks >= 2 { throw CancellationError() }
                })
        }
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}
