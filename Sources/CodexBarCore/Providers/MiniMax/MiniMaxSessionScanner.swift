import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

// Reads MiniMax local assistant-turn token usage from the MiniMax desktop runtime database
// (`~/.minimax/v2/sqlite/runtime-state.sqlite`, table `local_runtime_token_usage`) and folds it
// into a token-only `CostUsageTokenSnapshot` for the Usage & Spend dashboard. Same output shape as
// `KimiCodeSessionScanner`, but sourced from SQLite rather than JSONL.
//
// The runtime table already stores one row per billable turn with explicit buckets:
// `input_tokens`, `output_tokens`, `reasoning_tokens`, `cache_read_tokens`, `cache_write_tokens`,
// plus `model` (e.g. `minimax/MiniMax-M3`) and `ts` (epoch milliseconds). `reasoning` is part of
// billing output, so it stays folded into `outputTokens` and is additionally surfaced as the
// `reasoningTokens` sub-bucket (never added on top). `cache_write` maps to `cacheCreationTokens`.
// `cost_usd` is reported by the provider, but MiniMax coding plans run on a flat subscription and
// report `0` there. To stay consistent with how Codex/Claude spend is estimated, we price each turn
// at the vendor's official models.dev rate (via `CostUsagePricing.claudeCostUSD`, which routes
// MiniMax through the third-party lookup) instead of trusting the zeroed provider figure. A turn is
// priced from its token buckets; only when no official rate is known does the snapshot fall back to
// the provider's `cost_usd`, and failing that stays token-only (`costUSD: nil`).
#if canImport(SQLite3) || canImport(CSQLite3)
public enum MiniMaxSessionScanner {
    public static let defaultHistoryDays = 30

    /// Environment override for the MiniMax home directory, resolved directly here so this scanner
    /// stays self-contained (mirrors how `KimiCodeSessionScanner` honors `KIMI_CODE_HOME`).
    public static let homeEnvironmentKey = "MINIMAX_HOME"

    private struct DayModelKey: Hashable {
        let day: String
        let model: String
    }

    private struct TokenAccumulator {
        var input = 0
        var cacheRead = 0
        var cacheCreation = 0
        var output = 0
        var reasoning = 0
        var requests = 0
        var cost = 0.0
        var sawCost = false

        mutating func add(
            _ row: UsageRow,
            modelsDevCatalog: ModelsDevCatalog?,
            modelsDevCacheRoot: URL?) -> Bool
        {
            guard let nextInput = Self.adding(self.input, row.input),
                  let nextCacheRead = Self.adding(self.cacheRead, row.cacheRead),
                  let nextCacheCreation = Self.adding(self.cacheCreation, row.cacheCreation),
                  let nextOutput = Self.adding(self.output, row.output),
                  let nextReasoning = Self.adding(self.reasoning, row.reasoning),
                  let nextRequests = Self.adding(self.requests, 1)
            else {
                return false
            }
            self.input = nextInput
            self.cacheRead = nextCacheRead
            self.cacheCreation = nextCacheCreation
            self.output = nextOutput
            self.reasoning = nextReasoning
            self.requests = nextRequests
            if let cost = row.estimatedCost(
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot)
            {
                self.cost += cost
                self.sawCost = true
            }
            return true
        }

        mutating func merge(_ other: TokenAccumulator) -> Bool {
            guard let nextInput = Self.adding(self.input, other.input),
                  let nextCacheRead = Self.adding(self.cacheRead, other.cacheRead),
                  let nextCacheCreation = Self.adding(self.cacheCreation, other.cacheCreation),
                  let nextOutput = Self.adding(self.output, other.output),
                  let nextReasoning = Self.adding(self.reasoning, other.reasoning),
                  let nextRequests = Self.adding(self.requests, other.requests)
            else {
                return false
            }
            self.input = nextInput
            self.cacheRead = nextCacheRead
            self.cacheCreation = nextCacheCreation
            self.output = nextOutput
            self.reasoning = nextReasoning
            self.requests = nextRequests
            if other.sawCost {
                self.cost += other.cost
                self.sawCost = true
            }
            return true
        }

        var total: Int? {
            guard let inputAndCacheRead = Self.adding(self.input, self.cacheRead),
                  let withCacheCreation = Self.adding(inputAndCacheRead, self.cacheCreation)
            else {
                return nil
            }
            return Self.adding(withCacheCreation, self.output)
        }

        private static func adding(_ lhs: Int, _ rhs: Int) -> Int? {
            let result = lhs.addingReportingOverflow(rhs)
            return result.overflow ? nil : result.partialValue
        }
    }

    private struct UsageRow {
        let model: String
        let createdMs: Int64
        let input: Int
        let output: Int
        let reasoning: Int
        let cacheRead: Int
        let cacheCreation: Int
        let cost: Double?

        /// Prices the turn at the vendor's official models.dev rate (mirroring how Codex/Claude
        /// spend is estimated). The stored `model` is namespaced as `minimax/MiniMax-M3`, but the
        /// third-party lookup keys on the bare model id, so the provider prefix is stripped first.
        /// `reasoning` is already folded into `output`, so it is not priced twice. Falls back to the
        /// provider-reported `cost_usd` only when it carries a real (non-zero) figure and no
        /// official rate is known.
        func estimatedCost(
            modelsDevCatalog: ModelsDevCatalog?,
            modelsDevCacheRoot: URL?) -> Double?
        {
            let bareModel = Self.bareModelID(self.model)
            if let priced = CostUsagePricing.claudeCostUSD(
                model: bareModel,
                inputTokens: self.input,
                cacheReadInputTokens: self.cacheRead,
                cacheCreationInputTokens: self.cacheCreation,
                outputTokens: self.output,
                pricingDate: Date(timeIntervalSince1970: TimeInterval(self.createdMs) / 1000),
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot)
            {
                return priced
            }
            if let cost = self.cost, cost > 0 { return cost }
            return nil
        }

        private static func bareModelID(_ model: String) -> String {
            guard let slash = model.lastIndex(of: "/") else { return model }
            return String(model[model.index(after: slash)...])
        }
    }

    public static func scan(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        historyDays: Int = defaultHistoryDays,
        now: Date = Date(),
        calendar: Calendar = .current,
        modelsDevCacheRoot: URL? = nil) -> CostUsageTokenSnapshot?
    {
        let days = max(1, historyDays)
        let databaseURL = self.runtimeDatabaseURL(environment: environment)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        guard let rows = self.readRows(databaseURL: databaseURL), !rows.isEmpty else { return nil }

        let modelsDevCatalog = CostUsagePricing.modelsDevCatalog(now: now, cacheRoot: modelsDevCacheRoot)
        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        var values: [DayModelKey: TokenAccumulator] = [:]

        for row in rows {
            let date = Date(timeIntervalSince1970: TimeInterval(row.createdMs) / 1000)
            let day = calendar.startOfDay(for: date)
            guard day >= start, day <= end else { continue }
            let key = DayModelKey(day: CostUsageLocalDay.key(from: day, calendar: calendar), model: row.model)
            var value = values[key] ?? TokenAccumulator()
            guard value.add(row, modelsDevCatalog: modelsDevCatalog, modelsDevCacheRoot: modelsDevCacheRoot)
            else { continue }
            values[key] = value
        }

        guard !values.isEmpty else { return nil }
        let byDay = Dictionary(grouping: values, by: \.key.day)
        let daily = byDay.keys.sorted().compactMap { day -> CostUsageDailyReport.Entry? in
            let models = (byDay[day] ?? []).sorted { lhs, rhs in
                lhs.key.model.localizedCaseInsensitiveCompare(rhs.key.model) == .orderedAscending
            }
            var total = TokenAccumulator()
            var modelBreakdowns: [CostUsageDailyReport.ModelBreakdown] = []
            var dayCost = 0.0
            var daySawCost = false
            for (key, value) in models {
                guard let modelTotal = value.total else { return nil }
                guard total.merge(value) else { return nil }
                modelBreakdowns.append(CostUsageDailyReport.ModelBreakdown(
                    modelName: key.model,
                    costUSD: value.sawCost ? value.cost : nil,
                    totalTokens: modelTotal,
                    inputTokens: value.input,
                    cacheReadTokens: value.cacheRead,
                    cacheCreationTokens: value.cacheCreation,
                    outputTokens: value.output,
                    reasoningTokens: value.reasoning > 0 ? value.reasoning : nil,
                    requestCount: value.requests))
                if value.sawCost {
                    dayCost += value.cost
                    daySawCost = true
                }
            }
            guard let totalTokens = total.total else { return nil }
            return CostUsageDailyReport.Entry(
                date: day,
                inputTokens: total.input,
                outputTokens: total.output,
                cacheReadTokens: total.cacheRead,
                cacheCreationTokens: total.cacheCreation,
                totalTokens: totalTokens,
                requestCount: total.requests,
                costUSD: daySawCost ? dayCost : nil,
                modelsUsed: modelBreakdowns.map(\.modelName),
                modelBreakdowns: modelBreakdowns)
        }
        let totalTokens = self.sum(daily.compactMap(\.totalTokens))
        let totalRequests = self.sum(daily.compactMap(\.requestCount))
        let totalCost = daily.compactMap(\.costUSD).reduce(0, +)
        let sawCost = daily.contains { $0.costUSD != nil }
        guard let totalTokens, let totalRequests else { return nil }

        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            sessionRequests: nil,
            last30DaysTokens: totalTokens,
            last30DaysCostUSD: sawCost ? totalCost : nil,
            last30DaysRequests: totalRequests,
            currencyCode: sawCost ? "USD" : "XXX",
            historyDays: days,
            historyCoverageIsEstablished: true,
            historyLabel: "MiniMax",
            costSource: .estimated,
            daily: daily,
            updatedAt: now)
    }

    // MARK: - Paths

    public static func minimaxHomeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let override = environment[self.homeEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".minimax", isDirectory: true)
    }

    public static func runtimeDatabaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        self.minimaxHomeURL(environment: environment)
            .appendingPathComponent("v2", isDirectory: true)
            .appendingPathComponent("sqlite", isDirectory: true)
            .appendingPathComponent("runtime-state.sqlite", isDirectory: false)
    }

    // MARK: - SQLite

    private static func readRows(databaseURL: URL) -> [UsageRow]? {
        var db: OpaquePointer?
        // The runtime database is WAL-journaled. A plain read-only open cannot create the shared
        // -shm/-wal files and may surface an empty or stale snapshot; `immutable=1` tells SQLite the
        // file won't change under us, so it reads the main database file directly without WAL setup.
        let uri = "file://\(databaseURL.path)?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        guard self.hasTable(named: "local_runtime_token_usage", db: db) else { return nil }

        let sql = """
        SELECT
          COALESCE(model, ''),
          ts,
          input_tokens,
          output_tokens,
          reasoning_tokens,
          cache_read_tokens,
          cache_write_tokens,
          cost_usd
        FROM local_runtime_token_usage
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var rows: [UsageRow] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }

            let model = self.columnText(stmt, 0) ?? ""
            let createdMs = sqlite3_column_int64(stmt, 1)
            let input = Int(sqlite3_column_int64(stmt, 2))
            let output = Int(sqlite3_column_int64(stmt, 3))
            let reasoning = Int(sqlite3_column_int64(stmt, 4))
            let cacheRead = Int(sqlite3_column_int64(stmt, 5))
            let cacheCreation = Int(sqlite3_column_int64(stmt, 6))
            let cost: Double? = sqlite3_column_type(stmt, 7) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(stmt, 7)

            guard createdMs > 0,
                  input >= 0, output >= 0, reasoning >= 0, cacheRead >= 0, cacheCreation >= 0
            else {
                continue
            }
            rows.append(UsageRow(
                model: model.isEmpty ? "minimax" : model,
                createdMs: createdMs,
                input: input,
                output: output,
                reasoning: reasoning,
                cacheRead: cacheRead,
                cacheCreation: cacheCreation,
                cost: cost))
        }
        return rows
    }

    private static func hasTable(named name: String, db: OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            -1,
            &stmt,
            nil) == SQLITE_OK
        else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, name, -1, transient)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(stmt, index)
        else {
            return nil
        }
        return String(cString: cString)
    }

    // MARK: - Helpers

    private static func sum(_ values: [Int]) -> Int? {
        var result = 0
        for value in values {
            let addition = result.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            result = addition.partialValue
        }
        return result
    }
}
#endif
