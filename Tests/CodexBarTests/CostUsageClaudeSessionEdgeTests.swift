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

    @Test
    func `append refresh keeps identity alias across cache boundary`() throws {
        // The initial scan ends with pair:m:r -> msg:m; the appended req:r cumulative
        // snapshot must still join the same stream through the persisted alias.
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
                "sessionId": "session-alias-persist",
                "isSidechain": false,
                "message": message,
            ]
            if let requestId {
                row["requestId"] = requestId
            }
            return row
        }

        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/alias-persist.jsonl",
            contents: env.jsonl([
                row(messageId: "x", requestId: "y", timestamp: iso0, input: 15),
                row(messageId: "x", requestId: nil, timestamp: iso1, input: 150),
            ]))

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
        #expect(initial.data[0].inputTokens == 150)

        let appended = try env.jsonl([row(messageId: nil, requestId: "y", timestamp: iso2, input: 300)])
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
        #expect(refreshed.data[0].inputTokens == 300)
    }

    @Test
    func `append refresh preserves quarantined sessionless row`() throws {
        // Quarantine state must survive the cache boundary: a later larger chunk from
        // session A must not reclaim the ambiguous sessionless row on refresh.
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 23)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let iso3 = env.isoString(for: day.addingTimeInterval(3))

        func row(sessionId: String?, timestamp: String, input: Int) -> [String: Any] {
            var row: [String: Any] = [
                "type": "assistant",
                "timestamp": timestamp,
                "isSidechain": false,
                "message": [
                    "id": "x",
                    "model": "claude-sonnet-4-20250514",
                    "usage": [
                        "input_tokens": input,
                        "cache_creation_input_tokens": 0,
                        "cache_read_input_tokens": 0,
                        "output_tokens": 1,
                    ],
                ],
            ]
            if let sessionId {
                row["sessionId"] = sessionId
            }
            return row
        }

        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/quarantine-persist.jsonl",
            contents: env.jsonl([
                row(sessionId: "session-a", timestamp: iso0, input: 11),
                row(sessionId: "session-b", timestamp: iso1, input: 13),
                row(sessionId: nil, timestamp: iso2, input: 100),
            ]))

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
        #expect(initial.data[0].inputTokens == 124)

        let appended = try env.jsonl([row(sessionId: "session-a", timestamp: iso3, input: 150)])
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
        #expect(refreshed.data[0].inputTokens == 263)
    }

    @Test
    func `transitive identity aliases carry through later rows`() throws {
        // pair(x,y) -> req(y) persists x as an alias; pair(m2,y) then msg(x) must all
        // stay in the same stream instead of splitting into separate calls.
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 23)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let iso3 = env.isoString(for: day.addingTimeInterval(3))

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
                "sessionId": "session-transitive",
                "isSidechain": false,
                "message": message,
            ]
            if let requestId {
                row["requestId"] = requestId
            }
            return row
        }

        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/transitive-alias.jsonl",
            contents: env.jsonl([
                row(messageId: "x", requestId: "y", timestamp: iso0, input: 15),
                row(messageId: nil, requestId: "y", timestamp: iso1, input: 150),
                row(messageId: "m2", requestId: "y", timestamp: iso2, input: 300),
                row(messageId: "x", requestId: nil, timestamp: iso3, input: 500),
            ]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.rows.count == 1)
        #expect(parsed.rows[0].input == 500)
    }

    @Test
    func `request only update preserves a distinct partial call`() throws {
        // pair(m,r)=100, msg(m)=110, then a distinct smaller msg(m)=10; a later
        // req(r)=120 must not absorb the preserved 10-token call through stale aliases.
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 23)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let iso3 = env.isoString(for: day.addingTimeInterval(3))

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
                "sessionId": "session-req-update",
                "isSidechain": false,
                "message": message,
            ]
            if let requestId {
                row["requestId"] = requestId
            }
            return row
        }

        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/req-update.jsonl",
            contents: env.jsonl([
                row(messageId: "m", requestId: "r", timestamp: iso0, input: 100),
                row(messageId: "m", requestId: nil, timestamp: iso1, input: 110),
                row(messageId: "m", requestId: nil, timestamp: iso2, input: 10),
                row(messageId: nil, requestId: "r", timestamp: iso3, input: 120),
            ]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.rows.count == 2)
        #expect(parsed.rows.map(\.input).sorted() == [10, 120])
    }

    @Test
    func `forked transcript reconciles through persisted aliases`() throws {
        // One transcript ends with pair(m,r) -> msg(m) (alias r persisted); a forked
        // transcript repeats pair(m,r). Reconciliation must keep a single row, not sum.
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 23)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        func pairRow(timestamp: String, input: Int) -> [String: Any] {
            [
                "type": "assistant",
                "timestamp": timestamp,
                "sessionId": "session-fork",
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
        let messageOnly: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "sessionId": "session-fork",
            "isSidechain": false,
            "message": [
                "id": "m",
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": 110,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 1,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/main-transcript.jsonl",
            contents: env.jsonl([pairRow(timestamp: iso0, input: 100), messageOnly]))
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/sub/fork-transcript.jsonl",
            contents: env.jsonl([pairRow(timestamp: iso0, input: 100)]))

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
        #expect(report.data[0].inputTokens == 110)
    }

    @Test
    func `fork files keep the latest cumulative alias row`() throws {
        // A lexicographically earlier fork contains only the old pair(m,r)=100 while the
        // main transcript ends with msg(m)=200 (alias r); the larger cumulative row must
        // win reconciliation instead of the fork's stale path-ordered row.
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 23)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        func pairRow(timestamp: String, input: Int) -> [String: Any] {
            [
                "type": "assistant",
                "timestamp": timestamp,
                "sessionId": "session-fork-latest",
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
        let messageOnly: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "sessionId": "session-fork-latest",
            "isSidechain": false,
            "message": [
                "id": "m",
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": 200,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 1,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/fork-a.jsonl",
            contents: env.jsonl([pairRow(timestamp: iso0, input: 100)]))
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/main-transcript.jsonl",
            contents: env.jsonl([pairRow(timestamp: iso0, input: 100), messageOnly]))

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
        #expect(report.data[0].inputTokens == 200)
    }

    @Test
    func `identifier transition retires the previous pair`() throws {
        // pair(m1,r) -> req(r) -> pair(m2,r) is one stream; the old pair(m1,r) must not
        // remain canonical and double-count the cumulative totals.
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
                "sessionId": "session-pair-transition",
                "isSidechain": false,
                "message": message,
            ]
            if let requestId {
                row["requestId"] = requestId
            }
            return row
        }

        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/pair-transition.jsonl",
            contents: env.jsonl([
                row(messageId: "m1", requestId: "r", timestamp: iso0, input: 100),
                row(messageId: nil, requestId: "r", timestamp: iso1, input: 150),
                row(messageId: "m2", requestId: "r", timestamp: iso2, input: 300),
            ]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.rows.count == 1)
        #expect(parsed.rows[0].input == 300)
    }

    @Test
    func `same pair in different sessions stays distinct in file`() throws {
        // Distinct calls in sessions A and B that reuse the same (messageId, requestId)
        // pair must both be counted in one file.
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 23)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        func row(sessionId: String, timestamp: String, input: Int) -> [String: Any] {
            [
                "type": "assistant",
                "timestamp": timestamp,
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

        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-qualified-pairs.jsonl",
            contents: env.jsonl([
                row(sessionId: "session-a", timestamp: iso0, input: 11),
                row(sessionId: "session-b", timestamp: iso1, input: 13),
            ]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.rows.count == 2)
        #expect(parsed.rows.map(\.input).sorted() == [11, 13])
    }

    @Test
    func `sessionless update keeps the known session of the class`() throws {
        // A -> sessionless (larger) -> B: the sessionless chunk replaces A and must adopt
        // A's session so a later B chunk does not wildcard-replace the whole class.
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 23)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))

        func row(sessionId: String?, timestamp: String, input: Int) -> [String: Any] {
            var row: [String: Any] = [
                "type": "assistant",
                "timestamp": timestamp,
                "isSidechain": false,
                "message": [
                    "id": "x",
                    "model": "claude-sonnet-4-20250514",
                    "usage": [
                        "input_tokens": input,
                        "cache_creation_input_tokens": 0,
                        "cache_read_input_tokens": 0,
                        "output_tokens": 1,
                    ],
                ],
            ]
            if let sessionId {
                row["sessionId"] = sessionId
            }
            return row
        }

        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-adoption.jsonl",
            contents: env.jsonl([
                row(sessionId: "session-a", timestamp: iso0, input: 11),
                row(sessionId: nil, timestamp: iso1, input: 100),
                row(sessionId: "session-b", timestamp: iso2, input: 150),
            ]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.rows.count == 2)
        #expect(parsed.rows.map(\.input).sorted() == [100, 150])
    }

    @Test
    func `parent precedence wins over larger sidechain alias row`() throws {
        // A copied sidechain row with a larger cumulative total and persisted aliases
        // must not replace the parent row during cross-file reconciliation.
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 23)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let parentRow: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "sessionId": "session-parent-precedence",
            "requestId": "r",
            "isSidechain": false,
            "message": [
                "id": "m",
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 1,
                ],
            ],
        ]
        let sidechainPair: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "sessionId": "session-parent-precedence",
            "requestId": "r",
            "isSidechain": true,
            "message": [
                "id": "m",
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": 50,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 1,
                ],
            ],
        ]
        let sidechainMessageOnly: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "sessionId": "session-parent-precedence",
            "isSidechain": true,
            "message": [
                "id": "m",
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": 200,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 1,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/parent.jsonl",
            contents: env.jsonl([parentRow]))
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/sub/agent-sidechain.jsonl",
            contents: env.jsonl([sidechainPair, sidechainMessageOnly]))

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
        #expect(report.data[0].inputTokens == 100)
    }
}
