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
        try? self.scanCancellable(
            environment: environment,
            historyDays: historyDays,
            now: now,
            calendar: calendar,
            modelsDevCacheRoot: modelsDevCacheRoot)
    }

    public static func scanCancellable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        historyDays: Int = defaultHistoryDays,
        now: Date = Date(),
        calendar: Calendar = .current,
        modelsDevCacheRoot: URL? = nil,
        checkCancellation: @escaping () throws -> Void = {}) throws -> CostUsageTokenSnapshot?
    {
        try checkCancellation()
        let days = max(1, historyDays)
        let calendar = CostUsageLocalDay.gregorianCalendar(preserving: calendar)
        let databaseURL = self.runtimeDatabaseURL(environment: environment)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        let until = calendar.date(byAdding: .day, value: 1, to: end) ?? now
        guard let rows = try self.readRows(
            databaseURL: databaseURL,
            sinceMs: Int64(start.timeIntervalSince1970 * 1000),
            untilMs: Int64(until.timeIntervalSince1970 * 1000),
            checkCancellation: checkCancellation),
            !rows.isEmpty
        else {
            return nil
        }

        let modelsDevCatalog = CostUsagePricing.modelsDevCatalog(now: now, cacheRoot: modelsDevCacheRoot)
        var events: [UnifiedUsageEvent] = []

        for row in rows {
            try checkCancellation()
            let date = Date(timeIntervalSince1970: TimeInterval(row.createdMs) / 1000)
            let day = calendar.startOfDay(for: date)
            guard day >= start, day <= end else { continue }
            // MiniMax reports `input` already uncached. The engine's uncached-input disambiguation
            // keys off `totalTokens`: passing input+cacheRead+output (cache-write excluded) hits the
            // "input is already uncached" branch so it is priced as-is, while cache-write is priced
            // separately via `cacheCreationTokens`. The estimated cost is resolved here (official
            // models.dev rate, falling back to a real provider-reported `cost_usd`) and carried as
            // `providerCostUSD` so the engine trusts it and never re-prices; an unresolvable cost
            // surfaces as an unpriced day instead of a partial subtotal.
            events.append(UnifiedUsageEvent(
                day: CostUsageLocalDay.key(from: day, calendar: calendar),
                model: row.model,
                billingProviderID: UsageProvider.minimax.rawValue,
                inputTokens: row.input,
                outputTokens: row.output,
                totalTokens: row.input + row.cacheRead + row.output,
                cacheReadTokens: row.cacheRead,
                cacheCreationTokens: row.cacheCreation,
                reasoningTokens: row.reasoning > 0 ? row.reasoning : nil,
                providerCostUSD: row.estimatedCost(
                    modelsDevCatalog: modelsDevCatalog,
                    modelsDevCacheRoot: modelsDevCacheRoot)))
        }

        return UsageEventAggregator.aggregate(
            events: events,
            historyDays: days,
            now: now,
            options: .init(
                historyLabel: "MiniMax",
                defaultBillingProviderID: UsageProvider.minimax.rawValue,
                modelsDevCacheRoot: modelsDevCacheRoot))
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

    private static func readRows(
        databaseURL: URL,
        sinceMs: Int64,
        untilMs: Int64,
        checkCancellation: () throws -> Void) throws -> [UsageRow]?
    {
        var db: OpaquePointer?
        // The runtime database is WAL-journaled. `immutable=1` must not be used here: it tells
        // SQLite the database cannot change and can therefore ignore a live WAL, which made recent
        // MiniMax turns disappear until a checkpoint. A normal URI read-only connection observes
        // committed WAL frames while still preventing CodexBar from modifying the provider DB.
        let encodedPath = databaseURL.path.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? databaseURL.path
        let uri = "file:\(encodedPath)?mode=ro"
        guard sqlite3_open_v2(
            uri,
            &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX,
            nil) == SQLITE_OK
        else {
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
        WHERE ts >= ? AND ts < ?
        ORDER BY ts
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sinceMs)
        sqlite3_bind_int64(stmt, 2, untilMs)

        var rows: [UsageRow] = []
        while true {
            try checkCancellation()
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

}
#endif
