import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

// Reads Trae's local state to surface which model the agent was last configured to use, without
// reporting token counts.
//
// Trae (a VS Code fork) keeps its state in
// `~/Library/Application Support/Trae*/User/globalStorage/state.vscdb`, a VS Code `ItemTable`
// key-value store. The keys relevant here are the per-agent selected-model map
// (`…_ai-chat:sessionRelation:globalModelMap`, values like `1_-_glm-5.2`) and the telemetry
// last-session date. Trae stores no per-request token usage locally — billing is server-side —
// so this is a *degraded* source: the scanner reports the models the user actually selected and
// the last active day, with every token and cost field left `nil` so nothing is fabricated.
#if canImport(SQLite3) || canImport(CSQLite3)
public enum TraeLocalActivityScanner {
    public static let defaultHistoryDays = 30

    /// Environment override pointing at the Trae `state.vscdb` file, so tests can use a fixture.
    public static let databaseEnvironmentKey = "TRAE_STATE_VSCDB"

    /// Candidate `Application Support` bundle folder names, newest branding first.
    private static let applicationSupportFolders = ["Trae CN", "Trae"]

    public static func databaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) -> URL?
    {
        if let override = environment[self.databaseEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: false)
        }
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let appSupport else { return nil }
        for folder in self.applicationSupportFolders {
            let candidate = appSupport
                .appendingPathComponent(folder, isDirectory: true)
                .appendingPathComponent("User/globalStorage/state.vscdb", isDirectory: false)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    public static func scan(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        historyDays: Int = defaultHistoryDays,
        now: Date = Date(),
        calendar: Calendar = .current) -> CostUsageTokenSnapshot?
    {
        try? self.scanCancellable(
            environment: environment,
            fileManager: fileManager,
            historyDays: historyDays,
            now: now,
            calendar: calendar)
    }

    public static func scanCancellable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        historyDays: Int = defaultHistoryDays,
        now: Date = Date(),
        calendar: Calendar = .current,
        checkCancellation: @escaping () throws -> Void = {}) throws -> CostUsageTokenSnapshot?
    {
        try checkCancellation()
        let days = max(1, historyDays)
        let calendar = CostUsageLocalDay.gregorianCalendar(preserving: calendar)
        guard let databaseURL = self.databaseURL(environment: environment, fileManager: fileManager),
              fileManager.fileExists(atPath: databaseURL.path)
        else {
            return nil
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let models = self.selectedModels(db: db)
        let lastActive = self.lastSessionDate(db: db)
        guard !models.isEmpty || lastActive != nil else { return nil }

        // Anchor the (single) record on the last active day when known, otherwise today. Trae
        // exposes no per-day token history, so there is exactly one degraded entry.
        let anchor = lastActive ?? now
        let anchorDay = calendar.startOfDay(for: anchor)
        let dayKey = CostUsageLocalDay.key(from: anchorDay, calendar: calendar)
        let entry = CostUsageDailyReport.Entry(
            date: dayKey,
            inputTokens: nil,
            outputTokens: nil,
            cacheReadTokens: nil,
            cacheCreationTokens: nil,
            totalTokens: nil,
            requestCount: nil,
            costUSD: nil,
            modelsUsed: models.isEmpty ? nil : models,
            modelBreakdowns: nil)
        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            last30DaysRequests: nil,
            currencyCode: "XXX",
            historyDays: days,
            historyCoverageIsEstablished: true,
            historyLabel: "Trae",
            costSource: .estimated,
            daily: [entry],
            updatedAt: now)
    }

    /// Reads the per-agent selected-model map and returns the de-duplicated, cleaned model names
    /// the user actually chose (e.g. `glm-5.2` from `1_-_glm-5.2`).
    private static func selectedModels(db: OpaquePointer?) -> [String] {
        guard let raw = self.value(db: db, keySuffix: "ai-chat:sessionRelation:globalModelMap"),
              let data = raw.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return []
        }
        var seen: Set<String> = []
        var models: [String] = []
        for value in map.values {
            let cleaned = self.cleanModelName(value)
            guard !cleaned.isEmpty, !seen.contains(cleaned.lowercased()) else { continue }
            seen.insert(cleaned.lowercased())
            models.append(cleaned)
        }
        return models.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Strips Trae's internal `N_-_` selection-id prefix from a stored model reference.
    private static func cleanModelName(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: "_-_") {
            value = String(value[range.upperBound...])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses the HTTP-date telemetry last-session timestamp (`Sat, 27 Jun 2026 15:51:03 GMT`).
    private static func lastSessionDate(db: OpaquePointer?) -> Date? {
        guard let raw = self.value(db: db, exactKey: "telemetry.lastSessionDate") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.date(from: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Looks up a value whose key either matches exactly or ends with the given suffix (Trae
    /// prefixes many keys with a numeric install id).
    private static func value(db: OpaquePointer?, exactKey: String? = nil, keySuffix: String? = nil) -> String? {
        let query = if exactKey != nil {
            "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        } else {
            "SELECT value FROM ItemTable WHERE key LIKE ? LIMIT 1;"
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let bind = exactKey ?? "%\(keySuffix ?? "")"
        sqlite3_bind_text(stmt, 1, bind, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        switch sqlite3_column_type(stmt, 0) {
        case SQLITE_TEXT:
            guard let c = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: c)
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16LittleEndian)
        default:
            return nil
        }
    }
}
#endif
