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
                row(id: nil, requestId: "y", input: 19),
                row(id: "req", requestId: "y", input: 17),
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

    @Test
    func `smaller paired call does not swallow a larger partial call`() throws {
        // A distinct paired call that happens to reuse a message ID must not evict a
        // message-only call whose token total is larger than its own.
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 23)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        func row(messageId: String?, requestId: String?, timestamp: String, input: Int, output: Int) -> [String: Any] {
            var message: [String: Any] = [
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": input,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": output,
                ],
            ]
            if let messageId {
                message["id"] = messageId
            }
            var row: [String: Any] = [
                "type": "assistant",
                "timestamp": timestamp,
                "sessionId": "session-reused-message-id",
                "isSidechain": false,
                "message": message,
            ]
            if let requestId {
                row["requestId"] = requestId
            }
            return row
        }

        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/reused-message-id.jsonl",
            contents: env.jsonl([
                row(messageId: "x", requestId: nil, timestamp: iso0, input: 100, output: 50),
                row(messageId: "x", requestId: "y", timestamp: iso1, input: 10, output: 5),
            ]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.rows.count == 2)
        #expect(parsed.rows.map(\.input).sorted() == [10, 100])
    }

    @Test
    func `growing partial chunk supersedes an earlier paired snapshot`() throws {
        // Reverse transition: the early cumulative chunk has both IDs and a later chunk
        // omits requestId (or messageId). With a larger token total it is the same
        // response's final snapshot, so it replaces the paired row.
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 23)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        func row(messageId: String?, requestId: String?, timestamp: String, input: Int, output: Int) -> [String: Any] {
            var message: [String: Any] = [
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": input,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": output,
                ],
            ]
            if let messageId {
                message["id"] = messageId
            }
            var row: [String: Any] = [
                "type": "assistant",
                "timestamp": timestamp,
                "sessionId": "session-reverse-transition",
                "isSidechain": false,
                "message": message,
            ]
            if let requestId {
                row["requestId"] = requestId
            }
            return row
        }

        let messageFileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/reverse-transition-message.jsonl",
            contents: env.jsonl([
                row(messageId: "x", requestId: "y", timestamp: iso0, input: 10, output: 5),
                row(messageId: "x", requestId: nil, timestamp: iso1, input: 100, output: 50),
            ]))

        let parsedMessage = CostUsageScanner.parseClaudeFile(
            fileURL: messageFileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsedMessage.rows.count == 1)
        #expect(parsedMessage.rows[0].input == 100)

        let requestFileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/reverse-transition-request.jsonl",
            contents: env.jsonl([
                row(messageId: "x", requestId: "y", timestamp: iso0, input: 10, output: 5),
                row(messageId: nil, requestId: "y", timestamp: iso1, input: 100, output: 50),
            ]))

        let parsedRequest = CostUsageScanner.parseClaudeFile(
            fileURL: requestFileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsedRequest.rows.count == 1)
        #expect(parsedRequest.rows[0].input == 100)
    }

    @Test
    func `smaller partial chunk does not swallow an earlier paired call`() throws {
        // A later message-only call that happens to reuse the message ID with fewer tokens
        // is a distinct call and must not replace the earlier paired snapshot.
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 23)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        func row(messageId: String?, requestId: String?, timestamp: String, input: Int, output: Int) -> [String: Any] {
            var message: [String: Any] = [
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": input,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": output,
                ],
            ]
            if let messageId {
                message["id"] = messageId
            }
            var row: [String: Any] = [
                "type": "assistant",
                "timestamp": timestamp,
                "sessionId": "session-reverse-reuse",
                "isSidechain": false,
                "message": message,
            ]
            if let requestId {
                row["requestId"] = requestId
            }
            return row
        }

        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/reverse-reuse.jsonl",
            contents: env.jsonl([
                row(messageId: "x", requestId: "y", timestamp: iso0, input: 100, output: 50),
                row(messageId: "x", requestId: nil, timestamp: iso1, input: 10, output: 5),
            ]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.rows.count == 2)
        #expect(parsed.rows.map(\.input).sorted() == [10, 100])
    }

    @Test
    func `append refresh supersedes partial row when paired row grows`() throws {
        // Incremental refresh: the cached message-only row is replaced by the appended
        // paired cumulative row instead of being summed.
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
                "sessionId": "session-append-transition",
                "isSidechain": false,
                "message": message,
            ]
            if let requestId {
                row["requestId"] = requestId
            }
            return row
        }

        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/append-transition.jsonl",
            contents: env.jsonl([row(messageId: "x", requestId: nil, timestamp: iso0, input: 11)]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let initial = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(initial.data.count == 1)
        #expect(initial.data[0].inputTokens == 11)

        let appended = try env.jsonl([row(messageId: "x", requestId: "y", timestamp: iso2, input: 13)])
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()

        let refreshed = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(refreshed.data.count == 1)
        #expect(refreshed.data[0].inputTokens == 13)
    }
}
