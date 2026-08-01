import Foundation
import Testing

@testable import CodexBarCore

@Suite
struct CopilotSessionScannerTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    @Test
    func `scanner reads the session.shutdown model metrics rollup`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root
            .appendingPathComponent("session-state", isDirectory: true)
            .appendingPathComponent("sess-1", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        // Mirrors the real Copilot layout: per-model usage lives only on the terminal
        // session.shutdown event's data.modelMetrics map.
        let shutdownUsage = #""usage":{"inputTokens":73595,"outputTokens":1196,"# +
            #""cacheReadTokens":48228,"cacheWriteTokens":0,"reasoningTokens":0}"#
        let shutdown = """
            {"type":"session.shutdown","timestamp":"2026-07-28T10:00:00.000Z",\
            "data":{"modelMetrics":{"claude-haiku-4.5":{"requests":{"count":3},\(shutdownUsage)}}}}
            """
        let lines = [
            #"{"type":"session.start","timestamp":"2026-07-28T09:00:00.000Z"}"#,
            shutdown,
        ]
        try lines.joined(separator: "\n").write(
            to: sessionDir.appendingPathComponent("events.jsonl"),
            atomically: true,
            encoding: .utf8)

        let snapshot = try #require(CopilotSessionScanner.scan(
            environment: [CopilotSessionScanner.homeEnvironmentKey: root.path],
            historyDays: 30,
            now: Date(timeIntervalSince1970: 1_785_283_200),
            calendar: Self.calendar,
            modelsDevCacheRoot: root.appendingPathComponent("pricing-cache", isDirectory: true)))

        #expect(snapshot.historyLabel == "GitHub Copilot")
        let entry = try #require(snapshot.daily.first)
        #expect(entry.totalTokens == 73595 + 1196)
        #expect(entry.inputTokens == 73595 - 48228)
        #expect(entry.cacheReadTokens == 48228)
        let model = try #require(entry.modelBreakdowns?.first)
        // Model name is traced to the real vendor: Copilot's claude-haiku-4.5 is billed at
        // Anthropic's rate and normalized to the pricing key.
        #expect(model.modelName == "claude-haiku-4-5")
        #expect(model.billingProviderID == UsageProvider.claude.rawValue)
    }

    @Test
    func `scanner falls back to the latest in-progress metrics event`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root
            .appendingPathComponent("session-state", isDirectory: true)
            .appendingPathComponent("sess-2", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        // No shutdown event: a still-running session. The most recent modelMetrics snapshot is
        // used instead.
        let metricsEvent: (String, Int, Int, Int) -> String = { ts, input, output, cache in
            """
            {"type":"session.model_metrics","timestamp":"\(ts)",\
            "data":{"modelMetrics":{"gpt-5":{"usage":{"inputTokens":\(input),\
            "outputTokens":\(output),"cacheReadTokens":\(cache),"cacheWriteTokens":0,"reasoningTokens":0}}}}}
            """
        }
        let lines = [
            metricsEvent("2026-07-28T09:00:00.000Z", 100, 50, 20),
            metricsEvent("2026-07-28T09:30:00.000Z", 300, 120, 60),
        ]
        try lines.joined(separator: "\n").write(
            to: sessionDir.appendingPathComponent("events.jsonl"),
            atomically: true,
            encoding: .utf8)

        let snapshot = try #require(CopilotSessionScanner.scan(
            environment: [CopilotSessionScanner.homeEnvironmentKey: root.path],
            historyDays: 30,
            now: Date(timeIntervalSince1970: 1_785_283_200),
            calendar: Self.calendar,
            modelsDevCacheRoot: root.appendingPathComponent("pricing-cache", isDirectory: true)))

        let entry = try #require(snapshot.daily.first)
        // Latest snapshot wins (300+120), not the sum of both.
        #expect(entry.totalTokens == 300 + 120)
        #expect(entry.inputTokens == 300 - 60)
        let model = try #require(entry.modelBreakdowns?.first)
        #expect(model.billingProviderID == UsageProvider.openai.rawValue)
    }

    @Test
    func `scanner returns nil when no metrics exist`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = CopilotSessionScanner.scan(
            environment: [CopilotSessionScanner.homeEnvironmentKey: root.path],
            historyDays: 30,
            now: Date(timeIntervalSince1970: 1_785_283_200),
            calendar: Self.calendar,
            modelsDevCacheRoot: root.appendingPathComponent("pricing-cache", isDirectory: true))
        #expect(snapshot == nil)
    }
}
