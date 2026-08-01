import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageClaudeReconciliationTests {
    @Test
    func `cross file copy does not swallow another session of the pair`() throws {
        // A lexicographically earlier copied file with (m,r) for session B must not
        // discard session A's usage from a later file that contains both sessions.
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 23)
        let iso0 = env.isoString(for: day)

        func row(sessionId: String, input: Int) -> [String: Any] {
            [
                "type": "assistant",
                "timestamp": iso0,
                "sessionId": sessionId,
                "requestId": "r",
                "isSidechain": false,
                "message": [
                    "id": "m",
                    "model": "claude-sonnet-4-20250514",
                    "usage": [
                        "input_tokens": input,
                        "cache_creation_input_tokens": 0,
                        "cache_read_input_tokens": 0,
                        "output_tokens": 1,
                    ],
                ],
            ]
        }

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/copy.jsonl",
            contents: env.jsonl([row(sessionId: "session-b", input: 13)]))
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/main.jsonl",
            contents: env.jsonl([
                row(sessionId: "session-a", input: 11),
                row(sessionId: "session-b", input: 13),
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 24)
    }

    @Test
    func `later copy does not duplicate a session already kept from the first file`() throws {
        // First file holds the pair in sessions A and B; a later copied file repeats
        // session B. Session B must be counted once.
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 23)
        let iso0 = env.isoString(for: day)

        func row(sessionId: String, input: Int) -> [String: Any] {
            [
                "type": "assistant",
                "timestamp": iso0,
                "sessionId": sessionId,
                "requestId": "r",
                "isSidechain": false,
                "message": [
                    "id": "m",
                    "model": "claude-sonnet-4-20250514",
                    "usage": [
                        "input_tokens": input,
                        "cache_creation_input_tokens": 0,
                        "cache_read_input_tokens": 0,
                        "output_tokens": 1,
                    ],
                ],
            ]
        }

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/a-main.jsonl",
            contents: env.jsonl([
                row(sessionId: "session-a", input: 11),
                row(sessionId: "session-b", input: 13),
            ]))
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/b-copy.jsonl",
            contents: env.jsonl([row(sessionId: "session-b", input: 13)]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 24)
    }

    @Test
    func `cross file consolidation retires aliased pairs`() throws {
        // The transcript evolved pair(m1,r) -> req(r) -> pair(m2,r) (m1 kept as alias)
        // while a copied fork still contains pair(m1,r); only the latest snapshot counts.
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 23)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))

        func row(messageId: String?, requestId: String?, timestamp: String, input: Int) -> [String: Any] {
            var message: [String: Any] = [
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": input,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 1,
                ],
            ]
            if let messageId {
                message["id"] = messageId
            }
            var row: [String: Any] = [
                "type": "assistant",
                "timestamp": timestamp,
                "sessionId": "session-cross-retire",
                "isSidechain": false,
                "message": message,
            ]
            if let requestId {
                row["requestId"] = requestId
            }
            return row
        }

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/fork.jsonl",
            contents: env.jsonl([row(messageId: "m1", requestId: "r", timestamp: iso0, input: 100)]))
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/transcript.jsonl",
            contents: env.jsonl([
                row(messageId: "m1", requestId: "r", timestamp: iso0, input: 100),
                row(messageId: nil, requestId: "r", timestamp: iso1, input: 150),
                row(messageId: "m2", requestId: "r", timestamp: iso2, input: 300),
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 300)
    }
}
