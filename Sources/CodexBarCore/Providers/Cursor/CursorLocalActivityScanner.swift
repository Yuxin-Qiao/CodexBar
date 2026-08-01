import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

// Reads Cursor's local AI activity database to surface which models were used and on which
// days, without reporting token counts.
//
// Cursor stores code-generation records in `~/.cursor/ai-tracking/ai-code-tracking.db`. The
// `ai_code_hashes` table has one row per recorded AI edit with a `model` column and an
// epoch-millisecond `timestamp`, but — unlike the CLI scanners — it stores no per-request token
// usage: token billing for Cursor happens server-side and is not mirrored locally. We therefore
// treat this as a *degraded* source: the scanner aggregates the per-day set of models that were
// active and emits a snapshot whose token and cost fields are all `nil`, so the dashboard can
// show "this tool was used with these models" without fabricating token numbers. `requestCount`
// is also withheld because a row is a code-hash record, not an LLM request.
#if canImport(SQLite3) || canImport(CSQLite3)
public enum CursorLocalActivityScanner {
    public static let defaultHistoryDays = 30

    /// Environment override for the Cursor home directory (the folder that contains
    /// `ai-tracking/ai-code-tracking.db`), so tests can point at a fixture.
    public static let homeEnvironmentKey = "CURSOR_HOME"

    private static let maximumRows = 500_000

    public static func databaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        let home: URL = if let override = environment[self.homeEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            URL(fileURLWithPath: override, isDirectory: true)
        } else {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cursor", isDirectory: true)
        }
        return home
            .appendingPathComponent("ai-tracking", isDirectory: true)
            .appendingPathComponent("ai-code-tracking.db", isDirectory: false)
    }

    public static func scan(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        historyDays: Int = defaultHistoryDays,
        now: Date = Date(),
        calendar: Calendar = .current) -> CostUsageTokenSnapshot?
    {
        try? self.scanCancellable(
            environment: environment,
            historyDays: historyDays,
            now: now,
            calendar: calendar)
    }

    public static func scanCancellable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        historyDays: Int = defaultHistoryDays,
        now: Date = Date(),
        calendar: Calendar = .current,
        checkCancellation: @escaping () throws -> Void = {}) throws -> CostUsageTokenSnapshot?
    {
        try checkCancellation()
        let days = max(1, historyDays)
        let calendar = CostUsageLocalDay.gregorianCalendar(preserving: calendar)
        let databaseURL = self.databaseURL(environment: environment)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }

        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        let startMs = Int64(start.timeIntervalSince1970 * 1000)
        let endMs = Int64(end.addingTimeInterval(24 * 60 * 60).timeIntervalSince1970 * 1000)

        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        // One row per (day, model) with the number of activity records. We bound the scan and
        // ignore rows with no usable model name.
        let query = """
        SELECT (timestamp / 1000) AS seconds, model
        FROM ai_code_hashes
        WHERE timestamp >= ? AND timestamp < ? AND model IS NOT NULL AND model != ''
        LIMIT \(self.maximumRows);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, startMs)
        sqlite3_bind_int64(stmt, 2, endMs)

        // Degraded source: emit one model-only event per distinct (day, model). The aggregator
        // surfaces these as token-less entries; we de-duplicate here so a busy day does not turn
        // into tens of thousands of identical events.
        var seen: Set<String> = []
        var events: [UnifiedUsageEvent] = []
        while true {
            try checkCancellation()
            let stepResult = sqlite3_step(stmt)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else { break }
            let seconds = sqlite3_column_int64(stmt, 0)
            guard let modelC = sqlite3_column_text(stmt, 1) else { continue }
            let model = String(cString: modelC)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { continue }
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(seconds)))
            let dayKey = CostUsageLocalDay.key(from: day, calendar: calendar)
            let dedupKey = "\(dayKey)\u{1f}\(model)"
            guard seen.insert(dedupKey).inserted else { continue }
            events.append(UnifiedUsageEvent(
                day: dayKey,
                model: model,
                billingProviderID: UsageProvider.cursor.rawValue))
        }

        return UsageEventAggregator.aggregate(
            events: events,
            historyDays: days,
            now: now,
            options: .init(
                historyLabel: "Cursor",
                defaultBillingProviderID: UsageProvider.cursor.rawValue))
    }
}
#endif
