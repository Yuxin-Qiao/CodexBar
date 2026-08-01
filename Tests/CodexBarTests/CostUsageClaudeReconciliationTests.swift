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
}
