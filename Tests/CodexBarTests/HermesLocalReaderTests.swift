// swiftformat:disable wrapFunctionBodies wrapLoopBodies wrapArguments wrapParameters blankLinesBetweenScopes
import Foundation
import XCTest
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
@testable import CodexBarCore

final class HermesLocalReaderTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesLocalReaderTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory = self.tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    #if canImport(SQLite3) || canImport(CSQLite3)
    private func createDatabase(at url: URL) -> OpaquePointer? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else { return nil }
        let schema = """
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY, source TEXT NOT NULL DEFAULT 'cli', model TEXT, billing_provider TEXT,
            started_at REAL NOT NULL, last_activity_at REAL, message_count INTEGER DEFAULT 0,
            api_call_count INTEGER DEFAULT 0, input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0,
            cache_read_tokens INTEGER DEFAULT 0, cache_write_tokens INTEGER DEFAULT 0,
            reasoning_tokens INTEGER DEFAULT 0,
            estimated_cost_usd REAL, actual_cost_usd REAL, cost_status TEXT, cost_source TEXT
        );
        CREATE TABLE IF NOT EXISTS session_model_usage (
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, model TEXT NOT NULL,
            billing_provider TEXT NOT NULL DEFAULT '', billing_base_url TEXT NOT NULL DEFAULT '',
            billing_mode TEXT NOT NULL DEFAULT '', task TEXT NOT NULL DEFAULT '',
            api_call_count INTEGER DEFAULT 0, input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0, cache_read_tokens INTEGER NOT NULL DEFAULT 0,
            cache_write_tokens INTEGER NOT NULL DEFAULT 0, reasoning_tokens INTEGER NOT NULL DEFAULT 0,
            estimated_cost_usd REAL NOT NULL DEFAULT 0, actual_cost_usd REAL NOT NULL DEFAULT 0,
            cost_status TEXT, cost_source TEXT, first_seen REAL, last_seen REAL,
            PRIMARY KEY (session_id, model, billing_provider, billing_base_url, billing_mode, task)
        );
        """
        sqlite3_exec(db, schema, nil, nil, nil)
        return db
    }

    @discardableResult
    private func seedDatabase(at url: URL? = nil, sql: String = "") throws -> URL {
        let targetURL = url ?? self.tempDirectory.appendingPathComponent("state.db")
        guard let db = self.createDatabase(at: targetURL) else {
            XCTFail("Failed to create test database")
            throw XCTSkip("Failed to create database")
        }
        defer { sqlite3_close(db) }
        if !sql.isEmpty {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
        return targetURL
    }
    #endif

    // MARK: - Unit Tests

    func testMissingDatabaseReturnsUnavailable() throws {
        let missingContext = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: missingContext)
        XCTAssertEqual(result.coverage, .unavailable)
        XCTAssertTrue(result.report.data.isEmpty)
    }

    func testMissingDatabaseSnapshotIsConfirmedEmpty() async throws {
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .hermes,
            environment: ["HERMES_HOME": self.tempDirectory.path],
            now: Date(),
            historyDays: 30)
        XCTAssertTrue(snapshot.historyCoverageIsEstablished)
        XCTAssertEqual(snapshot.sessionRequests, 0)
        XCTAssertEqual(snapshot.last30DaysRequests, 0)
        XCTAssertTrue(snapshot.daily.isEmpty)
    }

    func testLightweightAvailabilityDoesNotRequireOpeningOrParsingDatabase() throws {
        let context = HermesLocalReader.Context(home: self.tempDirectory)
        XCTAssertFalse(HermesLocalReader.hasLocalStore(context: context))
        XCTAssertEqual(HermesLocalReader.localStoreStatus(context: context), .absent)

        let dbURL = self.tempDirectory.appendingPathComponent("state.db")
        try Data().write(to: dbURL)
        XCTAssertTrue(HermesLocalReader.hasLocalStore(context: context))
        XCTAssertEqual(HermesLocalReader.localStoreStatus(context: context), .present)
    }

    func testProfileDiscoveryFailureIsUnavailable() throws {
        let profilesURL = self.tempDirectory.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: profilesURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: profilesURL.path) }

        let context = HermesLocalReader.Context(home: self.tempDirectory)
        XCTAssertEqual(HermesLocalReader.localStoreStatus(context: context), .unavailable)
    }

    func testResidualSessionReconciliation() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let now = Date().timeIntervalSince1970
        try self.seedDatabase(sql: """
        INSERT INTO sessions (
            id, started_at, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens
        ) VALUES ('sess_1', \(now), 1000, 500, 200, 100, 50);
        INSERT INTO session_model_usage (
            session_id, model, input_tokens, output_tokens,
            cache_read_tokens, cache_write_tokens, reasoning_tokens, last_seen
        ) VALUES ('sess_1', 'claude-3-5-sonnet', 200, 100, 50, 25, 10, \(now));
        """)
        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        let entries = result.report.data
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.inputTokens, 1000)
        XCTAssertEqual(entry.outputTokens, 500)
        XCTAssertEqual(entry.cacheReadTokens, 200)
        XCTAssertEqual(entry.cacheCreationTokens, 100)
        XCTAssertEqual(entry.reasoningTokens, 50)
        XCTAssertEqual(entry.totalTokens, 1800)

        let breakdowns = entry.modelBreakdowns ?? []
        XCTAssertEqual(breakdowns.count, 2)
        let sonnet = breakdowns.first { $0.modelName == "claude-3-5-sonnet" }
        XCTAssertEqual(sonnet?.totalTokens, 375)
        let residual = breakdowns.first { $0.modelName == "unknown" }
        XCTAssertEqual(residual?.totalTokens, 1425)
        #endif
    }

    func testCanonicalTokenSumExcludesReasoningDoubleCount() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let now = Date().timeIntervalSince1970
        try self.seedDatabase(sql: """
        INSERT INTO sessions (id, started_at) VALUES ('sess_canon', \(now));
        INSERT INTO session_model_usage (
            session_id, model, input_tokens, output_tokens,
            cache_read_tokens, cache_write_tokens, reasoning_tokens, last_seen
        ) VALUES ('sess_canon', 'hermes-model', 100, 50, 20, 10, 15, \(now));
        """)
        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        let entry = try XCTUnwrap(result.report.data.first)
        XCTAssertEqual(entry.totalTokens, 180)
        XCTAssertEqual(entry.reasoningTokens, 15)
        #endif
    }

    func testArithmeticOverflowProtection() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let now = Date().timeIntervalSince1970
        try self.seedDatabase(sql: """
        INSERT INTO sessions (id, started_at) VALUES ('sess_ovf', \(now));
        INSERT INTO session_model_usage (
            session_id, model, input_tokens, output_tokens,
            cache_read_tokens, cache_write_tokens, reasoning_tokens, last_seen
        ) VALUES ('sess_ovf', 'model_a', 9223372036854775807, 1, 0, 0, 0, \(now));
        """)
        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .partial)
        #endif
    }

    func testResumedSessionAttributionToActiveDate() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day1 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 2, day: 10, hour: 12))?
            .timeIntervalSince1970)
        let day5 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 2, day: 15, hour: 12))?
            .timeIntervalSince1970)

        try self.seedDatabase(sql: """
        INSERT INTO sessions (id, started_at, last_activity_at, input_tokens, output_tokens)
        VALUES ('sess_resumed', \(day1), \(day5), 100, 50);
        """)
        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context, calendar: calendar)
        XCTAssertEqual(result.coverage, .complete)
        let entries = result.report.data
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.date, "2026-02-15")
        #endif
    }

    func testUndatedModelRowsUseSessionActivityTimestamp() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let sessionActivity = try XCTUnwrap(calendar
            .date(from: DateComponents(year: 2026, month: 2, day: 20, hour: 10))?.timeIntervalSince1970)

        try self.seedDatabase(sql: """
        INSERT INTO sessions (id, started_at, last_activity_at) VALUES ('sess_undated', 1000, \(sessionActivity));
        INSERT INTO session_model_usage (session_id, model, input_tokens, output_tokens, first_seen, last_seen)
        VALUES ('sess_undated', 'claude-3-haiku', 50, 25, NULL, NULL);
        """)
        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context, calendar: calendar)
        XCTAssertEqual(result.coverage, .complete)
        let entries = result.report.data
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.date, "2026-02-20")
        #endif
    }

    func testEmptyDatabaseReturnsCompleteWithNoEntries() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        try self.seedDatabase()
        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        XCTAssertTrue(result.report.data.isEmpty)
        #endif
    }

    func testCorruptDatabaseReturnsPartialCoverage() throws {
        let dbURL = self.tempDirectory.appendingPathComponent("state.db")
        try Data("not a sqlite database".utf8).write(to: dbURL)
        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .partial)
        XCTAssertTrue(result.report.data.isEmpty)
    }

    func testActiveWALRowsAreReadWithinSnapshot() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let now = Date().timeIntervalSince1970
        try self.seedDatabase(sql: """
        PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
        INSERT INTO sessions (id, started_at) VALUES ('sess_wal', \(now));
        INSERT INTO session_model_usage (session_id, model, input_tokens, output_tokens, last_seen)
        VALUES ('sess_wal', 'wal-model', 300, 150, \(now));
        """)
        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        let entry = try XCTUnwrap(result.report.data.first)
        XCTAssertEqual(entry.totalTokens, 450)
        #endif
    }

    func testMultiProfileDeduplication() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let now = Date().timeIntervalSince1970
        try self.seedDatabase(sql: """
        INSERT INTO sessions (id, started_at) VALUES ('sess_multi', \(now));
        INSERT INTO session_model_usage (session_id, model, input_tokens, output_tokens, last_seen)
        VALUES ('sess_multi', 'model_dup', 100, 50, 1000);
        """)
        let profURL = self.tempDirectory.appendingPathComponent("profiles/prof_a/state.db")
        try self.seedDatabase(at: profURL, sql: """
        INSERT INTO sessions (id, started_at) VALUES ('sess_multi', \(now));
        INSERT INTO session_model_usage (session_id, model, input_tokens, output_tokens, last_seen)
        VALUES ('sess_multi', 'model_dup', 200, 100, 2000);
        """)
        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        let entry = try XCTUnwrap(result.report.data.first)
        XCTAssertEqual(entry.inputTokens, 200)
        XCTAssertEqual(entry.outputTokens, 100)
        #endif
    }

    func testNewerProfileModelRowsSuppressOlderSessionResidual() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let now = Date().timeIntervalSince1970
        let stale = now - 60
        try self.seedDatabase(sql: """
        INSERT INTO sessions (id, model, started_at, last_activity_at, api_call_count, input_tokens, output_tokens)
        VALUES ('sess_residual_merge', 'old-session-model', \(stale), \(stale), 1, 100, 0);
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count, input_tokens, output_tokens, first_seen, last_seen
        ) VALUES ('sess_residual_merge', 'new-model', 'provider', 1, 60, 0, \(stale), \(stale));
        """)
        let profURL = self.tempDirectory.appendingPathComponent("profiles/prof_b/state.db")
        try self.seedDatabase(at: profURL, sql: """
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count, input_tokens, output_tokens, first_seen, last_seen
        ) VALUES ('sess_residual_merge', 'new-model', 'provider', 1, 60, 0, \(now), \(now));
        """)
        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        let entry = try XCTUnwrap(result.report.data.first)
        XCTAssertEqual(entry.totalTokens, 100)
        XCTAssertEqual(entry.requestCount, 1)
        XCTAssertEqual(entry.modelBreakdowns?.count, 2)
        XCTAssertEqual(entry.modelBreakdowns?.first?.modelName, "new-model")
        XCTAssertEqual(
            try XCTUnwrap(entry.modelBreakdowns?.first(where: { $0.modelName == "new-model" })?.totalTokens),
            60)
        XCTAssertEqual(
            try XCTUnwrap(entry.modelBreakdowns?.first(where: { $0.modelName == "old-session-model" })?.totalTokens),
            40)
        #endif
    }

    func testNewerProfileModelCostsAreSubtractedFromOlderSessionResidual() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let now = Date().timeIntervalSince1970
        try self.seedDatabase(sql: """
        INSERT INTO sessions (
            id, model, billing_provider, started_at, last_activity_at,
            api_call_count, input_tokens, output_tokens, actual_cost_usd, cost_status, cost_source
        )
        VALUES ('sess_residual_cost_merge', 'old-session-model', 'provider', \(now - 60), \(now -
            60), 1, 100, 0, 1.00, 'actual', 'provider_cost_api');
        """)
        let profURL = self.tempDirectory.appendingPathComponent("profiles/prof_c/state.db")
        try self.seedDatabase(at: profURL, sql: """
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count,
            input_tokens, output_tokens, actual_cost_usd, cost_status, cost_source, first_seen, last_seen
        )
        VALUES ('sess_residual_cost_merge', 'new-model', 'provider', 1, 100, 0, 0.40, 'actual', 'provider_cost_api', \(
            now), \(now));
        """)
        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        let entry = try XCTUnwrap(result.report.data.first)
        XCTAssertEqual(entry.totalTokens, 100)
        XCTAssertEqual(try XCTUnwrap(entry.costUSD), 1.00, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(entry.modelBreakdowns).compactMap(\.costUSD).reduce(0, +), 1.00, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(try XCTUnwrap(entry.modelBreakdowns).first(where: { $0.modelName == "new-model" })?.costUSD),
            0.40,
            accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(try XCTUnwrap(entry.modelBreakdowns).first(where: { $0.modelName == "old-session-model" })?
                .costUSD),
            0.60,
            accuracy: 0.0001)
        #endif
    }

    func testProfileScopedHomeDoesNotReadSiblingProfiles() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let root = self.tempDirectory.appendingPathComponent("hermes-root", isDirectory: true)
        let selectedDir = root.appendingPathComponent("profiles/selected", isDirectory: true)
        let siblingDir = root.appendingPathComponent("profiles/sibling", isDirectory: true)
        let now = Date().timeIntervalSince1970
        try self.seedDatabase(at: selectedDir.appendingPathComponent("state.db"), sql: """
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count, input_tokens, output_tokens, first_seen, last_seen
        ) VALUES ('selected', 'selected-model', 'provider', 1, 8, 2, \(now), \(now));
        """)
        try self.seedDatabase(at: siblingDir.appendingPathComponent("state.db"), sql: """
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count, input_tokens, output_tokens, first_seen, last_seen
        ) VALUES ('sibling', 'sibling-model', 'provider', 1, 80, 20, \(now), \(now));
        """)
        let context = HermesLocalReader.Context(home: selectedDir)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        let entry = try XCTUnwrap(result.report.data.first)
        XCTAssertEqual(entry.totalTokens, 10)
        XCTAssertEqual(entry.modelsUsed, ["selected-model"])
        #endif
    }

    func testCancellationPromptlyAborts() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        try self.seedDatabase()
        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(
            context: context,
            checkCancellation: { throw CancellationError() })
        XCTAssertEqual(result.coverage, .partial)
        #endif
    }

    func testEndToEndCostUsageFetcherSnapshot() async throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let now = Date().timeIntervalSince1970
        try self.seedDatabase(sql: """
        INSERT INTO sessions (id, started_at) VALUES ('sess_e2e', \(now));
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count, input_tokens, output_tokens,
            estimated_cost_usd, first_seen, last_seen
        ) VALUES (
            'sess_e2e', 'hermes-e2e-model', 'nous', 1, 1000, 500,
            0.12, \(now), \(now)
        );
        """)

        let env = ["HERMES_HOME": self.tempDirectory.path]
        let fetcher = CostUsageFetcher()
        let snapshot = try await fetcher.loadTokenSnapshot(
            provider: .hermes,
            environment: env,
            now: Date(),
            historyDays: 30)

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot.sessionTokens, 1500)
        XCTAssertEqual(snapshot.last30DaysTokens, 1500)
        XCTAssertEqual(snapshot.sessionCostUSD, 0.12)
        XCTAssertEqual(snapshot.last30DaysCostUSD, 0.12)
        XCTAssertEqual(snapshot.sessionRequests, 1)
        XCTAssertEqual(snapshot.last30DaysRequests, 1)
        XCTAssertEqual(snapshot.costProvenance, .listPriceEstimate)
        #endif
    }

    func testAuthoritativeSessionCostWinsWhenModelProvenanceDiffers() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let now = Date().timeIntervalSince1970
        try self.seedDatabase(sql: """
        INSERT INTO sessions (id, started_at, actual_cost_usd, cost_status) VALUES ('sess_auth', \(
            now), 0.50, 'actual');
        INSERT INTO session_model_usage (
            session_id, model, input_tokens, output_tokens, estimated_cost_usd, cost_status, last_seen
        ) VALUES ('sess_auth', 'model_diff', 100, 50, 0.10, 'estimated', \(now));
        """)
        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        XCTAssertEqual(HermesLocalReader.costProvenance(for: result.report.data), .vendorMetered)
        let entry = try XCTUnwrap(result.report.data.first)
        XCTAssertEqual(entry.costUSD, 0.50)
        #endif
    }

    func testCostProvenanceDoesNotRequirePositiveAPICallCount() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let now = Date().timeIntervalSince1970
        try self.seedDatabase(sql: """
        INSERT INTO sessions (id, started_at) VALUES ('sess_nocall', \(now));
        INSERT INTO session_model_usage (
            session_id, model, api_call_count, input_tokens, output_tokens, actual_cost_usd, cost_status, last_seen
        ) VALUES ('sess_nocall', 'model_nocall', 0, 100, 50, 0.05, 'actual', \(now));
        """)
        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        let entry = try XCTUnwrap(result.report.data.first)
        XCTAssertEqual(HermesLocalReader.costProvenance(for: result.report.data), .vendorMetered)
        XCTAssertNotNil(entry.pricedRequestCount)
        #endif
    }

    func testSameProvenanceModelCostsAreCappedAtSessionTotal() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let now = Date().timeIntervalSince1970
        try self.seedDatabase(sql: """
        INSERT INTO sessions (id, started_at, actual_cost_usd, cost_status) VALUES ('sess_cap', \(now), 0.10, 'actual');
        INSERT INTO session_model_usage (session_id, model, task, actual_cost_usd, cost_status, last_seen)
        VALUES ('sess_cap', 'model_a', 't1', 0.08, 'actual', \(now)),
               ('sess_cap', 'model_b', 't2', 0.08, 'actual', \(now));
        """)
        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        XCTAssertEqual(HermesLocalReader.costProvenance(for: result.report.data), .vendorMetered)
        let entry = try XCTUnwrap(result.report.data.first)
        XCTAssertEqual(try XCTUnwrap(entry.costUSD), 0.10, accuracy: 0.001)
        #endif
    }

    func testKnownEstimatedSessionCostSurvivesUnknownModelCost() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let now = Date().timeIntervalSince1970
        try self.seedDatabase(sql: """
        INSERT INTO sessions (id, started_at, estimated_cost_usd, cost_status) VALUES ('sess_est', \(
            now), 0.25, 'estimate');
        INSERT INTO session_model_usage (
            session_id, model, input_tokens, output_tokens, cost_status, last_seen)
        VALUES ('sess_est', 'model_unk', 100, 50, 'unknown', \(now));
        """)
        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        XCTAssertEqual(HermesLocalReader.costProvenance(for: result.report.data), .listPriceEstimate)
        let entry = try XCTUnwrap(result.report.data.first)
        XCTAssertEqual(entry.costUSD, 0.25)
        #endif
    }

    func testCostStatePreservesKnownZeroAndCoverageCategories() async throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let now = Date().timeIntervalSince1970
        try self.seedDatabase(sql: """
        INSERT INTO sessions (id, model, started_at) VALUES ('sess_actual_zero', 'actual-zero', \(now));
        INSERT INTO sessions (id, model, started_at) VALUES ('sess_estimated_zero', 'estimated-zero', \(now));
        INSERT INTO sessions (id, model, started_at) VALUES ('sess_included_zero', 'included-zero', \(now));
        INSERT INTO sessions (id, model, started_at) VALUES ('sess_unknown', 'unknown-cost', \(now));
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count,
            input_tokens, output_tokens, estimated_cost_usd, actual_cost_usd,
            cost_status, cost_source, first_seen, last_seen
        ) VALUES
            ('sess_actual_zero', 'actual-zero', 'provider', 1, 10, 1, 0, 0,
             'actual', 'provider_cost_api', \(now), \(now)),
            ('sess_estimated_zero', 'estimated-zero', 'provider', 1, 20, 2, 0, 0,
             'estimated', 'official_docs_snapshot', \(now), \(now)),
            ('sess_included_zero', 'included-zero', 'provider', 1, 30, 3, 0, 0,
             'included', 'none', \(now), \(now)),
            ('sess_unknown', 'unknown-cost', 'provider', 1, 40, 4, 0, 0,
             'unknown', 'none', \(now), \(now));
        """)
        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        let entry = try XCTUnwrap(result.report.data.first)
        XCTAssertEqual(entry.totalTokens, 110)
        XCTAssertEqual(entry.costUSD, 0)
        XCTAssertEqual(entry.requestCount, 4)
        XCTAssertEqual(
            entry.coverageCounts,
            CostUsageCoverageCounts(priced: 1, unpriced: 1, unmetered: 1, estimated: 1))

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .hermes,
            environment: ["HERMES_HOME": self.tempDirectory.path],
            now: Date(timeIntervalSince1970: now),
            historyDays: 1)
        XCTAssertEqual(snapshot.last30DaysTokens, 110)
        XCTAssertEqual(snapshot.last30DaysCostUSD, 0)
        XCTAssertEqual(snapshot.costProvenance, .mixed)
        #endif
    }

    func testVendorMeteredCostProvenanceIsPreserved() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let now = Date().timeIntervalSince1970
        try self.seedDatabase(sql: """
        INSERT INTO sessions (id, started_at) VALUES ('sess_vend', \(now));
        INSERT INTO session_model_usage (
            session_id, model, input_tokens, output_tokens, actual_cost_usd, cost_status, last_seen
        )
        VALUES ('sess_vend', 'model_v', 100, 50, 0.15, 'metered', \(now));
        """)
        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        XCTAssertEqual(HermesLocalReader.costProvenance(for: result.report.data), .vendorMetered)
        #endif
    }

    func testNewerProfileModelRowsPreserveUnmatchedSessionCalls() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let now = Date().timeIntervalSince1970
        let stale = now - 60
        try self.seedDatabase(sql: """
        INSERT INTO sessions (
            id, model, started_at, last_activity_at, api_call_count, input_tokens, output_tokens
        ) VALUES (
            'sess_request_residual_merge', 'old-session-model', \(stale), \(stale), 10, 100, 0
        );
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count,
            input_tokens, output_tokens, first_seen, last_seen
        ) VALUES (
            'sess_request_residual_merge', 'new-model', 'provider', 5,
            60, 0, \(stale), \(stale)
        );
        """)
        let profURL = self.tempDirectory.appendingPathComponent("profiles/prof_d/state.db")
        try self.seedDatabase(at: profURL, sql: """
        INSERT INTO session_model_usage (
            session_id, model, billing_provider, api_call_count,
            input_tokens, output_tokens, first_seen, last_seen
        ) VALUES (
            'sess_request_residual_merge', 'new-model', 'provider', 5,
            100, 0, \(now), \(now)
        );
        """)
        let context = HermesLocalReader.Context(home: self.tempDirectory)
        let result = try HermesLocalReader.makeDailyReportWithStatus(context: context)
        XCTAssertEqual(result.coverage, .complete)
        let entry = try XCTUnwrap(result.report.data.first)
        XCTAssertEqual(entry.totalTokens, 100)
        XCTAssertEqual(entry.requestCount, 10)
        XCTAssertEqual(entry.modelBreakdowns?.count, 2)
        XCTAssertEqual(
            try XCTUnwrap(entry.modelBreakdowns?.first(where: { $0.modelName == "new-model" })?.requestCount),
            5)
        XCTAssertEqual(
            try XCTUnwrap(entry.modelBreakdowns?.first(where: { $0.modelName == "old-session-model" })?.requestCount),
            5)
        #endif
    }
}
