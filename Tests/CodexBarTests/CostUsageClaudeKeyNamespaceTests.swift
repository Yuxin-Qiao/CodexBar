import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageClaudeKeyNamespaceTests {
    @Test
    func `composite keys do not collide with single id namespaces`() throws {
        // A paired row with messageId "msg" + requestId "x" must not share a key with a
        // message-only row whose id is "x" (and the analogous request-only case).
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 23)
        let iso0 = env.isoString(for: day)

        func row(id: String?, requestId: String?, input: Int) -> [String: Any] {
            var message: [String: Any] = [
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": input,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 1,
                ],
            ]
            if let id {
                message["id"] = id
            }
            var row: [String: Any] = [
                "type": "assistant",
                "timestamp": iso0,
                "sessionId": "session-key-namespace",
                "isSidechain": false,
                "message": message,
            ]
            if let requestId {
                row["requestId"] = requestId
            }
            return row
        }

        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/key-namespace.jsonl",
            contents: env.jsonl([
                row(id: "x", requestId: nil, input: 11),
                row(id: "msg", requestId: "x", input: 13),
                row(id: "req", requestId: "y", input: 17),
                row(id: nil, requestId: "y", input: 19),
            ]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.rows.count == 4)
        #expect(parsed.rows.map(\.input).sorted() == [11, 13, 17, 19])
    }

    @Test
    func `partial message row is superseded when request id appears later`() throws {
        // Streaming chunks: the early cumulative row only has message.id; the later row for
        // the same response adds requestId. They must merge into a single row, not sum.
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 23)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

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
                "sessionId": "session-stream-transition",
                "isSidechain": false,
                "message": message,
            ]
            if let requestId {
                row["requestId"] = requestId
            }
            return row
        }

        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/stream-transition-message.jsonl",
            contents: env.jsonl([
                row(messageId: "x", requestId: nil, timestamp: iso0, input: 11),
                row(messageId: "x", requestId: "y", timestamp: iso1, input: 13),
            ]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.rows.count == 1)
        #expect(parsed.rows[0].input == 13)
    }

    @Test
    func `partial request row is superseded when message id appears later`() throws {
        // Analogous transition: the early cumulative row only has requestId; the later row
        // for the same response adds message.id.
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 23)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

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
                "sessionId": "session-stream-transition-request",
                "isSidechain": false,
                "message": message,
            ]
            if let requestId {
                row["requestId"] = requestId
            }
            return row
        }

        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/stream-transition-request.jsonl",
            contents: env.jsonl([
                row(messageId: nil, requestId: "y", timestamp: iso0, input: 11),
                row(messageId: "x", requestId: "y", timestamp: iso1, input: 13),
            ]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.rows.count == 1)
        #expect(parsed.rows[0].input == 13)
    }
}
