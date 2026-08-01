import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageClaudeSessionEdgeTests {
    @Test
    func `empty session id matches missing session`() throws {
        // A proxy may write `sessionId: ""` on early chunks; it must behave like a missing
        // session so the later row with a real session still coalesces.
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 23)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let emptySession: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "sessionId": "",
            "isSidechain": false,
            "message": [
                "id": "x",
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": 11,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 1,
                ],
            ],
        ]
        let realSession: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "sessionId": "session-real",
            "requestId": "y",
            "isSidechain": false,
            "message": [
                "id": "x",
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": 13,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 1,
                ],
            ],
        ]

        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/empty-session.jsonl",
            contents: env.jsonl([emptySession, realSession]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.rows.count == 1)
        #expect(parsed.rows[0].input == 13)
    }

    @Test
    func `later paired update preserves a smaller partial call`() throws {
        // A distinct message-only call that reused the message ID with fewer tokens must
        // survive when the original paired stream later grows.
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
                "sessionId": "session-pair-update",
                "isSidechain": false,
                "message": message,
            ]
            if let requestId {
                row["requestId"] = requestId
            }
            return row
        }

        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/pair-update.jsonl",
            contents: env.jsonl([
                row(messageId: "x", requestId: "y", timestamp: iso0, input: 100),
                row(messageId: "x", requestId: nil, timestamp: iso1, input: 10),
                row(messageId: "x", requestId: "y", timestamp: iso2, input: 110),
            ]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.rows.count == 2)
        #expect(parsed.rows.map(\.input).sorted() == [10, 110])
    }
}
