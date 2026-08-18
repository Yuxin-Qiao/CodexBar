import CodexBarCore
import Foundation
import Testing

struct OpenCodexUsageFanOutTests {
    @Test func `snapshotsBySubscription routes openai spend into codex`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let entries = [
            OpenCodexUsageEntry(
                requestID: "codex-1",
                timestamp: now,
                provider: "openai",
                model: "openai/gpt-5.2",
                usageStatus: .reported,
                usage: OpenCodexTokenUsage(inputTokens: 100, outputTokens: 50, totalTokens: 150),
                totalTokens: 150),
        ]

        let snapshots = OpenCodexUsageFanOut.snapshotsBySubscription(
            entries: entries,
            now: now,
            historyDays: 7,
            calendar: calendar)

        #expect(snapshots.keys == [.codex])
        #expect(snapshots[.codex]?.last30DaysTokens == 150)
    }

    @Test func `snapshotsBySubscription routes opencode go spend into open code go`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let entries = [
            OpenCodexUsageEntry(
                requestID: "ocgo-1",
                timestamp: now,
                provider: "opencode-go",
                model: "opencode-go/gpt-5.2",
                usageStatus: .reported,
                usage: OpenCodexTokenUsage(inputTokens: 80, outputTokens: 20, totalTokens: 100),
                totalTokens: 100),
        ]

        let snapshots = OpenCodexUsageFanOut.snapshotsBySubscription(
            entries: entries,
            now: now,
            historyDays: 7,
            calendar: calendar)

        #expect(snapshots.keys == [.opencodego])
        #expect(snapshots[.opencodego]?.last30DaysTokens == 100)
    }

    @Test func `snapshotsBySubscription skips token only providers`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let entries = [
            OpenCodexUsageEntry(
                requestID: "free-1",
                timestamp: now,
                provider: "opencode-free",
                model: "opencode-free/gpt-5.2",
                usageStatus: .reported,
                usage: OpenCodexTokenUsage(inputTokens: 40, outputTokens: 10, totalTokens: 50),
                totalTokens: 50),
        ]

        let snapshots = OpenCodexUsageFanOut.snapshotsBySubscription(
            entries: entries,
            now: now,
            historyDays: 7,
            calendar: calendar)

        #expect(snapshots.isEmpty)
    }

    @Test func `snapshotsBySubscription prefers a routed model prefix over provider`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let entries = [
            OpenCodexUsageEntry(
                requestID: "mismatch-1",
                timestamp: now,
                provider: "openai",
                model: "opencode-go/deepseek-v4-flash",
                usageStatus: .reported,
                usage: OpenCodexTokenUsage(inputTokens: 40, outputTokens: 10, totalTokens: 50),
                totalTokens: 50),
        ]

        let snapshots = OpenCodexUsageFanOut.snapshotsBySubscription(
            entries: entries,
            now: now,
            historyDays: 7,
            calendar: calendar)

        #expect(snapshots.keys == [.opencodego])
        #expect(snapshots[.codex] == nil)
    }
}
