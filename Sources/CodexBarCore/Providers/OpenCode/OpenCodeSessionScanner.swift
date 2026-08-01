import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

/// Scans local OpenCode message storage and folds assistant-turn token usage into a token-only
/// `CostUsageTokenSnapshot` for the Usage & Spend dashboard. Same shape as
/// `KimiCodeSessionScanner`; the on-disk semantics mirror tokscale's `sessions/opencode.rs`:
///
/// - Root: `$XDG_DATA_HOME/opencode` (default `~/.local/share/opencode`).
/// - Messages: `storage/message/<sessionID>/*.json`, one message per file, with `role`,
///   `modelID`/`providerID` (v2 payloads may nest the model under `model.id`), a required
///   `tokens {input, output, reasoning?, cache {read, write}}` object, and `time.created` /
///   `time.completed` as epoch milliseconds (float allowed).
///
/// Only `role == "assistant"` files carry billable usage; role-less files are skipped on purpose
/// (the missing-role shortcut in tokscale applies solely to its type-filtered SQLite query).
/// `cache.write` maps to `cacheCreationTokens`. `reasoning` stays folded into billing
/// `outputTokens` (reasoning is part of output for billing) and is additionally surfaced as the
/// `reasoningTokens` sub-bucket. Negative values mark the record corrupt (skipped)
/// rather than clamped, matching this repo's `KimiCodeSessionScanner` robustness style.
///
/// Deduplication mirrors tokscale: a message's dedup key is its embedded `id`, falling back to
/// the file stem, and repeated keys collapse into one record — this absorbs forked-session
/// copies, which keep the same message id (and usually the same filename) in a second session
/// directory.
///
/// Future work — SQLite storage: OpenCode 1.2+ also keeps messages in `opencode.db` (`message`
/// table, role inside the JSON `data` column) and newer channel builds in
/// `opencode-<channel>.db` (`session_message` table, model nested under `$.model`). The package
/// already links the SQLite3 C module (see `OpenCodeGoLocalUsageReader`), so support can be
/// added without new dependencies. When it lands, the same dedup keys must be shared with this
/// JSON pass so messages present in both stores collapse (tokscale dedups JSON vs DB the same
/// way); DB rows additionally collapse on a full-field fingerprint — created/completed
/// timestamps, model/provider, token counts, cost, agent — whenever the embedded ids do not
/// conflict.
public enum OpenCodeSessionScanner {
    public static let defaultHistoryDays = 30
    public static let maximumFiles = 20000
    public static let maximumBytes = 512 * 1024 * 1024
    public static let maximumFileBytes = 16 * 1024 * 1024

    /// Environment override for the XDG data home, resolved directly here (the same way
    /// `KimiSettingsReader` honors `KIMI_CODE_HOME`) so this scanner stays self-contained.
    public static let dataHomeEnvironmentKey = "XDG_DATA_HOME"

    // MARK: - Wire models

    private struct WireMessage: Decodable {
        struct Tokens: Decodable {
            struct Cache: Decodable {
                let read: Int
                let write: Int
            }

            let input: Int
            let output: Int
            let reasoning: Int?
            let cache: Cache
        }

        struct Model: Decodable {
            let id: String?
            let provider: String?
        }

        struct Time: Decodable {
            let created: Double
        }

        let id: String?
        let role: String?
        let modelID: String?
        let model: Model?
        /// Billing ownership evidence recorded by OpenCode (e.g. `openai`, `anthropic`).
        /// Optional because legacy JSON files predate it; never guessed from the model name.
        let providerID: String?
        let tokens: Tokens?
        let time: Time
    }

    // MARK: - Aggregation

    private struct NormalizedUsage {
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheCreation: Int
        /// `reasoning` tokens; already included in `output` (billing-inclusive), tracked separately.
        let reasoning: Int
    }

    private struct DayModelKey: Hashable {
        let day: String
        let model: String
    }

    /// One assistant-turn usage record, normalized from either a JSON message file or an
    /// `opencode.db` row so both storage passes share the aggregation path.
    private struct UsageRecord {
        let dedupKey: String
        let day: String
        let model: String
        /// Billing ownership evidence retained from the source record (JSON `providerID` /
        /// `model.provider`, or the DB row's equivalents). Optional because legacy records predate
        /// it; never inferred from the model name.
        let billingProviderID: String?
        let usage: NormalizedUsage
        /// Provider-reported cost (only present for `opencode.db` rows; JSON files carry none).
        let cost: Double?
        /// Full-field fingerprint used to collapse JSON-vs-DB duplicates when ids don't conflict.
        let fingerprint: String
    }

    private struct TokenAccumulator {
        var input = 0
        var cacheRead = 0
        var cacheCreation = 0
        var output = 0
        var reasoning = 0
        var requests = 0

        mutating func add(_ usage: NormalizedUsage) -> Bool {
            guard let nextInput = Self.adding(self.input, usage.input),
                  let nextCacheRead = Self.adding(self.cacheRead, usage.cacheRead),
                  let nextCacheCreation = Self.adding(self.cacheCreation, usage.cacheCreation),
                  let nextOutput = Self.adding(self.output, usage.output),
                  let nextReasoning = Self.adding(self.reasoning, usage.reasoning),
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

    // MARK: - Scanning

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
        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end

        var context = ScanContext(start: start, end: end, calendar: calendar)
        var records: [UsageRecord] = []
        // The SQLite row is the richer source after an OpenCode migration because it carries
        // provider-reported cost. Register it before legacy JSON so duplicates retain pricing.
        try records.append(contentsOf: self.scanDatabaseMessages(
            environment: environment,
            context: &context,
            checkCancellation: checkCancellation))
        try records.append(contentsOf: self.scanJSONMessages(
            environment: environment,
            fileManager: fileManager,
            context: &context,
            checkCancellation: checkCancellation))

        var values: [DayModelKey: TokenAccumulator] = [:]
        var costs: [DayModelKey: Double] = [:]
        // First retained ownership evidence per (day, model); records that lack one do not
        // overwrite an earlier, sourced value.
        var billingProviderIDs: [DayModelKey: String] = [:]
        // Keys that include at least one billable record with no provider-reported cost (legacy JSON
        // rows). Their day's cost must be withheld so a priced DB subtotal is not read as complete.
        var partiallyPricedKeys: Set<DayModelKey> = []
        for record in records {
            try checkCancellation()
            let key = DayModelKey(day: record.day, model: record.model)
            var value = values[key] ?? TokenAccumulator()
            guard value.add(record.usage) else { continue }
            values[key] = value
            if billingProviderIDs[key] == nil, let billingProviderID = record.billingProviderID {
                billingProviderIDs[key] = billingProviderID
            }
            if let cost = record.cost, cost.isFinite, cost >= 0 {
                costs[key] = (costs[key] ?? 0) + cost
            } else {
                partiallyPricedKeys.insert(key)
            }
        }

        guard !values.isEmpty else { return nil }
        let byDay = Dictionary(grouping: values, by: \.key.day)
        let daily = byDay.keys.sorted().compactMap { day -> CostUsageDailyReport.Entry? in
            let models = (byDay[day] ?? []).sorted { lhs, rhs in
                lhs.key.model.localizedCaseInsensitiveCompare(rhs.key.model) == .orderedAscending
            }
            var total = TokenAccumulator()
            var dayCost = 0.0
            var dayCostSeen = false
            var dayHasUnpricedUsage = false
            var modelBreakdowns: [CostUsageDailyReport.ModelBreakdown] = []
            for (key, value) in models {
                guard let modelTotal = value.total else { return nil }
                guard total.merge(value) else { return nil }
                // A model whose records are only partially priced reports no subtotal: pairing the
                // combined token count with a priced-only cost would read as a complete figure.
                let modelPriced = costs[key] != nil && !partiallyPricedKeys.contains(key)
                let modelCost = modelPriced ? costs[key] : nil
                if let modelCost { dayCost += modelCost; dayCostSeen = true }
                if !modelPriced { dayHasUnpricedUsage = true }
                modelBreakdowns.append(CostUsageDailyReport.ModelBreakdown(
                    modelName: key.model,
                    billingProviderID: billingProviderIDs[key],
                    costUSD: modelCost,
                    totalTokens: modelTotal,
                    inputTokens: value.input,
                    cacheReadTokens: value.cacheRead,
                    cacheCreationTokens: value.cacheCreation,
                    outputTokens: value.output,
                    reasoningTokens: value.reasoning > 0 ? value.reasoning : nil,
                    requestCount: value.requests))
            }
            guard let totalTokens = total.total else { return nil }
            let dayCostUSD = dayCostSeen && !dayHasUnpricedUsage ? dayCost : nil
            return CostUsageDailyReport.Entry(
                date: day,
                inputTokens: total.input,
                outputTokens: total.output,
                cacheReadTokens: total.cacheRead,
                cacheCreationTokens: total.cacheCreation,
                totalTokens: totalTokens,
                requestCount: total.requests,
                costUSD: dayCostUSD,
                modelsUsed: modelBreakdowns.map(\.modelName),
                modelBreakdowns: modelBreakdowns)
        }
        let totalTokens = self.sum(daily.compactMap(\.totalTokens))
        let totalRequests = self.sum(daily.compactMap(\.requestCount))
        guard let totalTokens, let totalRequests else { return nil }
        // Cost only exists for `opencode.db` rows (JSON files carry none). A day with any
        // unpriced usage withholds the headline cost: publishing the priced subtotal alone would
        // read as the complete history total.
        let hasUnpricedTokenDay = daily.contains { $0.totalTokens != nil && $0.costUSD == nil }
        let totalCost = hasUnpricedTokenDay ? nil : self.sum(daily.compactMap(\.costUSD))

        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            sessionRequests: nil,
            last30DaysTokens: totalTokens,
            last30DaysCostUSD: totalCost,
            last30DaysRequests: totalRequests,
            currencyCode: totalCost != nil ? "USD" : "XXX",
            historyDays: days,
            historyCoverageIsEstablished: true,
            historyLabel: "OpenCode",
            costSource: totalCost != nil ? .providerReported : .estimated,
            daily: daily,
            updatedAt: now)
    }

    /// JSON message files (OpenCode < 1.2). Only assistant turns bill tokens.
    /// Shared scan window and cross-source dedup state threaded through the JSON and SQLite scanners.
    private struct ScanContext {
        let start: Date
        let end: Date
        let calendar: Calendar
        var seenMessageIDs: Set<String> = []
        var seenFingerprints: Set<String> = []
    }

    private static func scanJSONMessages(
        environment: [String: String],
        fileManager: FileManager,
        context: inout ScanContext,
        checkCancellation: () throws -> Void) throws -> [UsageRecord]
    {
        let start = context.start
        let end = context.end
        let calendar = context.calendar
        let storage = self.opencodeMessageStorageURL(environment: environment)
        guard let enumerator = fileManager.enumerator(
            at: storage,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else {
            return []
        }

        let decoder = JSONDecoder()
        var records: [UsageRecord] = []
        var visitedFiles = 0
        var visitedBytes = 0
        while let url = enumerator.nextObject() as? URL {
            try checkCancellation()
            guard url.pathExtension.lowercased() == "json" else { continue }
            guard visitedFiles < self.maximumFiles else { break }
            let resourceValues = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard resourceValues?.isRegularFile == true else { continue }
            if let modificationDate = resourceValues?.contentModificationDate,
               modificationDate < start
            {
                continue
            }
            let size = max(0, resourceValues?.fileSize ?? 0)
            guard size <= self.maximumFileBytes,
                  size <= self.maximumBytes - visitedBytes
            else {
                continue
            }
            visitedFiles += 1
            visitedBytes += size
            guard let data = try? Data(contentsOf: url),
                  let message = try? decoder.decode(WireMessage.self, from: data)
            else {
                continue
            }
            guard message.role == "assistant",
                  let model = self.cleaned(message.modelID ?? message.model?.id),
                  let tokens = message.tokens,
                  let usage = self.normalize(tokens),
                  message.time.created.isFinite
            else {
                continue
            }
            let date = Date(timeIntervalSince1970: message.time.created / 1000)
            let day = calendar.startOfDay(for: date)
            guard day >= start, day <= end else { continue }
            let dedupKey = self.cleaned(message.id) ?? url.deletingPathExtension().lastPathComponent
            let billingProviderID = self.cleaned(message.providerID ?? message.model?.provider)
            let fingerprint = self.fingerprint(
                createdMs: Int64(message.time.created.rounded()),
                model: model,
                billingProviderID: billingProviderID,
                usage: usage,
                cost: nil)
            guard context.seenMessageIDs.insert(dedupKey).inserted,
                  context.seenFingerprints.insert(fingerprint).inserted
            else { continue }
            records.append(UsageRecord(
                dedupKey: dedupKey,
                day: CostUsageLocalDay.key(from: day, calendar: calendar),
                model: model,
                billingProviderID: billingProviderID,
                usage: usage,
                cost: nil,
                fingerprint: fingerprint))
        }
        return records
    }

    /// `opencode.db` (OpenCode 1.2+). The `message` table keeps each message as a JSON `data`
    /// blob; assistant rows carry `modelID`/`model.id`, `tokens{input,output,reasoning,cache{read,write}}`,
    /// `cost` (provider-reported USD), and `time.created` (epoch ms). `json_extract` reads them in
    /// SQL so we never materialize the blob.
    private static func scanDatabaseMessages(
        environment: [String: String],
        context: inout ScanContext,
        checkCancellation: () throws -> Void) throws -> [UsageRecord]
    {
        let start = context.start
        let end = context.end
        let calendar = context.calendar
        let dbURL = self.opencodeDatabaseURL(environment: environment)
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }

        var db: OpaquePointer?
        // Open the live database read-only without `immutable=1`; immutable mode can ignore
        // committed WAL frames and publish stale history.
        let encodedPath = dbURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? dbURL.path
        let uri = "file:\(encodedPath)?mode=ro"
        guard sqlite3_open_v2(
            uri,
            &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX,
            nil) == SQLITE_OK
        else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        guard self.hasTable(named: "message", db: db) else { return [] }

        let sql = """
        SELECT
          COALESCE(NULLIF(json_extract(data, '$.id'), ''), ''),
          COALESCE(
            NULLIF(json_extract(data, '$.modelID'), ''),
            json_extract(data, '$.model.id')),
          COALESCE(json_extract(data, '$.time.created'), time_created),
          json_extract(data, '$.tokens.input'),
          json_extract(data, '$.tokens.output'),
          json_extract(data, '$.tokens.reasoning'),
          json_extract(data, '$.tokens.cache.read'),
          json_extract(data, '$.tokens.cache.write'),
          json_extract(data, '$.cost'),
          COALESCE(
            NULLIF(json_extract(data, '$.providerID'), ''),
            json_extract(data, '$.model.provider'))
        FROM message
        WHERE json_extract(data, '$.role') = 'assistant'
          AND COALESCE(json_extract(data, '$.time.created'), time_created) >= ?
          AND COALESCE(json_extract(data, '$.time.created'), time_created) < ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let until = calendar.date(byAdding: .day, value: 1, to: end) ?? end
        sqlite3_bind_int64(stmt, 1, Int64(start.timeIntervalSince1970 * 1000))
        sqlite3_bind_int64(stmt, 2, Int64(until.timeIntervalSince1970 * 1000))

        var records: [UsageRecord] = []
        while true {
            try checkCancellation()
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return [] }

            let messageID = self.columnText(stmt, 0)
            guard let model = self.cleaned(self.columnText(stmt, 1)) else { continue }
            let createdMs = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                ? 0
                : Int64(sqlite3_column_double(stmt, 2))
            guard createdMs > 0 else { continue }
            let input = Int(sqlite3_column_int64(stmt, 3))
            let output = Int(sqlite3_column_int64(stmt, 4))
            let reasoning = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? 0 : Int(sqlite3_column_int64(stmt, 5))
            let cacheRead = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? 0 : Int(sqlite3_column_int64(stmt, 6))
            let cacheCreation = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? 0 : Int(sqlite3_column_int64(stmt, 7))
            let cost: Double? = sqlite3_column_type(stmt, 8) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(stmt, 8)
            let billingProviderID = self.cleaned(self.columnText(stmt, 9))

            guard input >= 0, output >= 0, reasoning >= 0, cacheRead >= 0, cacheCreation >= 0,
                  let foldedOutput = self.adding(output, reasoning)
            else {
                continue
            }
            let usage = NormalizedUsage(
                input: input,
                output: foldedOutput,
                cacheRead: cacheRead,
                cacheCreation: cacheCreation,
                reasoning: reasoning)

            let date = Date(timeIntervalSince1970: Double(createdMs) / 1000)
            let day = calendar.startOfDay(for: date)
            guard day >= start, day <= end else { continue }

            let fingerprint = self.fingerprint(
                createdMs: createdMs,
                model: model,
                billingProviderID: billingProviderID,
                usage: usage,
                cost: cost)
            // tokscale dedups JSON vs DB by embedded id, then by full-field fingerprint when ids
            // don't conflict — so a message present in both stores collapses to one record.
            if let messageID, !messageID.isEmpty {
                guard context.seenMessageIDs.insert(messageID).inserted else { continue }
            }
            guard context.seenFingerprints.insert(fingerprint).inserted else { continue }

            records.append(UsageRecord(
                dedupKey: messageID ?? fingerprint,
                day: CostUsageLocalDay.key(from: day, calendar: calendar),
                model: model,
                billingProviderID: billingProviderID,
                usage: usage,
                cost: cost,
                fingerprint: fingerprint))
        }
        return records
    }

    // MARK: - Paths

    public static func opencodeMessageStorageURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        self.opencodeDataRootURL(environment: environment)
            .appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent("message", isDirectory: true)
    }

    public static func opencodeDatabaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        self.opencodeDataRootURL(environment: environment)
            .appendingPathComponent("opencode.db", isDirectory: false)
    }

    private static func opencodeDataRootURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        let dataHome = if let override = self.cleaned(environment[self.dataHomeEnvironmentKey]) {
            URL(fileURLWithPath: override, isDirectory: true)
        } else {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("share", isDirectory: true)
        }
        return dataHome.appendingPathComponent("opencode", isDirectory: true)
    }

    // MARK: - Helpers

    private static func normalize(_ tokens: WireMessage.Tokens) -> NormalizedUsage? {
        let reasoning = tokens.reasoning ?? 0
        guard tokens.input >= 0, tokens.output >= 0, reasoning >= 0,
              tokens.cache.read >= 0, tokens.cache.write >= 0
        else {
            return nil
        }
        // Reasoning is part of billing output, so it stays folded into `output`; the
        // `reasoning` bucket surfaces the same count separately (never add it on top).
        guard let output = self.adding(tokens.output, reasoning) else { return nil }
        return NormalizedUsage(
            input: tokens.input,
            output: output,
            cacheRead: tokens.cache.read,
            cacheCreation: tokens.cache.write,
            reasoning: reasoning)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func adding(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }

    private static func sum(_ values: [Int]) -> Int? {
        var result = 0
        for value in values {
            let addition = result.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            result = addition.partialValue
        }
        return result
    }

    private static func sum(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        var result = 0.0
        for value in values {
            result += value
            guard result.isFinite else { return nil }
        }
        return result
    }

    /// Cross-store fingerprint for one logical message. Cost is deliberately excluded because
    /// migrated database rows can enrich an otherwise identical legacy JSON record with pricing.
    /// Ownership evidence is included so records whose routing differs are not collapsed.
    private static func fingerprint(
        createdMs: Int64,
        model: String,
        billingProviderID: String?,
        usage: NormalizedUsage,
        cost _: Double?) -> String
    {
        [
            String(createdMs),
            model,
            billingProviderID ?? "",
            String(usage.input),
            String(usage.output),
            String(usage.cacheRead),
            String(usage.cacheCreation),
            String(usage.reasoning),
        ].joined(separator: "|")
    }

    // MARK: - SQLite helpers

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
