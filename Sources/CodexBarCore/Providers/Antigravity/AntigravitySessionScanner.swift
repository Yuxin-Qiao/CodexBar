import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

// Reads Antigravity (Google) local assistant-turn token usage from the conversation databases
// (`~/.gemini/antigravity/conversations/*.db`) and folds it into a `CostUsageTokenSnapshot` for the
// Usage & Spend dashboard. Same output shape as `MiniMaxSessionScanner`.
//
// Each `gen_metadata` row is one generation encoded as a `GeneratorMetadata` protobuf (the same
// message the IDE returns over `GetCascadeTrajectoryGeneratorMetadata`). There is no shipped
// `.proto`, so — mirroring tokscale's antigravity-cli parser — this scanner ships a tiny
// dependency-free protobuf wire-format reader and pulls only the fields it needs:
//
//   gen_metadata.#1            → chatModel message
//     #19 (string)             → responseModel (e.g. `gemini-3.6-flash`)
//     #9.#4 = {#1 sec, #2 ns}  → per-generation wall-clock Timestamp
//     #4                       → usage message
//       #1 (varint, const)     → fixed system-prompt tokens (≈1132), billable input
//       #2 (varint)            → newly-processed (non-cached) input tokens
//       #5 (varint)            → cacheRead tokens
//       #9 (varint)            → output (text) tokens
//       #10 (varint)           → thinking / reasoning tokens
//       #11 (string)           → responseId (dedup key)
//   trajectory_metadata_blob.#2 = {#1 sec, #2 ns} → session-created fallback Timestamp
//
// `reasoning` is part of billing output, so it stays folded into `outputTokens` and is additionally
// surfaced as the `reasoningTokens` sub-bucket (never added on top). Costs are priced from the
// token buckets at the vendor's models.dev rate (Google provider), matching how Codex/Claude spend
// is estimated; when no official rate is known the day stays token-only (`costUSD: nil`).
#if canImport(SQLite3) || canImport(CSQLite3)
public enum AntigravitySessionScanner {
    public static let defaultHistoryDays = 30

    public enum ScanError: Error, Equatable {
        /// The live provider database could not be read completely (for example, SQLITE_BUSY).
        case databaseUnavailable
    }

    /// Environment override for the Antigravity conversations directory, resolved directly here so
    /// this scanner stays self-contained (mirrors `MiniMaxSessionScanner.MINIMAX_HOME`).
    public static let homeEnvironmentKey = "ANTIGRAVITY_HOME"

    private static let claudePricingAliases: [String: String] = [
        "claude-opus-4-6-thinking": "claude-opus-4-6",
        "claude-sonnet-4-6-thinking": "claude-sonnet-4-6",
        "claude-haiku-4-6-thinking": "claude-haiku-4-6",
    ]

    private struct DayModelKey: Hashable {
        let day: String
        let model: String
    }

    private struct TokenAccumulator {
        var input = 0
        var cacheRead = 0
        var output = 0
        var reasoning = 0
        var requests = 0
        var cost = 0.0
        var sawCost = false

        mutating func add(_ row: UsageRow) -> Bool {
            guard let nextInput = Self.adding(self.input, row.input),
                  let nextCacheRead = Self.adding(self.cacheRead, row.cacheRead),
                  let nextOutput = Self.adding(self.output, row.output),
                  let nextReasoning = Self.adding(self.reasoning, row.reasoning),
                  let nextRequests = Self.adding(self.requests, 1)
            else {
                return false
            }
            self.input = nextInput
            self.cacheRead = nextCacheRead
            self.output = nextOutput
            self.reasoning = nextReasoning
            self.requests = nextRequests
            if let cost = row.costUSD, cost.isFinite {
                let nextCost = self.cost + cost
                if nextCost.isFinite {
                    self.cost = nextCost
                    self.sawCost = true
                }
            }
            return true
        }

        mutating func merge(_ other: TokenAccumulator) -> Bool {
            guard let nextInput = Self.adding(self.input, other.input),
                  let nextCacheRead = Self.adding(self.cacheRead, other.cacheRead),
                  let nextOutput = Self.adding(self.output, other.output),
                  let nextReasoning = Self.adding(self.reasoning, other.reasoning),
                  let nextRequests = Self.adding(self.requests, other.requests)
            else {
                return false
            }
            self.input = nextInput
            self.cacheRead = nextCacheRead
            self.output = nextOutput
            self.reasoning = nextReasoning
            self.requests = nextRequests
            if other.sawCost {
                let nextCost = self.cost + other.cost
                if other.cost.isFinite, nextCost.isFinite {
                    self.cost = nextCost
                    self.sawCost = true
                }
            }
            return true
        }

        var total: Int? {
            guard let withCacheRead = Self.adding(self.input, self.cacheRead) else { return nil }
            return Self.adding(withCacheRead, self.output)
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
        let cacheRead: Int
        let output: Int
        let reasoning: Int
        let responseID: String?
        let costUSD: Double?
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
        let conversationsURL = self.conversationsURL(environment: environment)
        let databaseURLs = self.conversationDatabases(under: conversationsURL)
        guard !databaseURLs.isEmpty else { return nil }

        let modelsDevCatalog = CostUsagePricing.modelsDevCatalog(now: now, cacheRoot: modelsDevCacheRoot)
        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        var values: [DayModelKey: TokenAccumulator] = [:]
        var seenResponseIDs: Set<String> = []
        for databaseURL in databaseURLs {
            try checkCancellation()
            try self.readRows(
                databaseURL: databaseURL,
                pricing: (catalog: modelsDevCatalog, cacheRoot: modelsDevCacheRoot),
                seenResponseIDs: &seenResponseIDs,
                checkCancellation: checkCancellation)
            { row in
                let date = Date(timeIntervalSince1970: TimeInterval(row.createdMs) / 1000)
                let day = calendar.startOfDay(for: date)
                guard day >= start, day <= end else { return }
                let key = DayModelKey(
                    day: CostUsageLocalDay.key(from: day, calendar: calendar),
                    model: row.model)
                var value = values[key] ?? TokenAccumulator()
                guard value.add(row) else { return }
                values[key] = value
            }
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
            var dayHasUnpricedUsage = false
            for (key, value) in models {
                guard let modelTotal = value.total else { return nil }
                guard total.merge(value) else { return nil }
                modelBreakdowns.append(CostUsageDailyReport.ModelBreakdown(
                    modelName: key.model,
                    costUSD: value.sawCost ? value.cost : nil,
                    totalTokens: modelTotal,
                    inputTokens: value.input,
                    cacheReadTokens: value.cacheRead,
                    cacheCreationTokens: nil,
                    outputTokens: value.output,
                    reasoningTokens: value.reasoning > 0 ? value.reasoning : nil,
                    requestCount: value.requests))
                if value.sawCost {
                    dayCost += value.cost
                    daySawCost = true
                } else {
                    dayHasUnpricedUsage = true
                }
            }
            guard let totalTokens = total.total else { return nil }
            return CostUsageDailyReport.Entry(
                date: day,
                inputTokens: total.input,
                outputTokens: total.output,
                cacheReadTokens: total.cacheRead,
                cacheCreationTokens: nil,
                totalTokens: totalTokens,
                requestCount: total.requests,
                costUSD: daySawCost && !dayHasUnpricedUsage ? dayCost : nil,
                modelsUsed: modelBreakdowns.map(\.modelName),
                modelBreakdowns: modelBreakdowns)
        }
        let totalTokens = self.sum(daily.compactMap(\.totalTokens))
        let totalRequests = self.sum(daily.compactMap(\.requestCount))
        let pricedDailyCosts = daily.compactMap(\.costUSD)
        let hasPricedUsage = daily.contains { entry in
            entry.modelBreakdowns?.contains { $0.costUSD != nil } == true
        }
        let totalCost = !pricedDailyCosts.isEmpty && pricedDailyCosts.count == daily.count
            ? pricedDailyCosts.reduce(0, +)
            : nil
        guard let totalTokens, let totalRequests else { return nil }

        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: totalTokens,
            last30DaysCostUSD: totalCost,
            last30DaysRequests: totalRequests,
            currencyCode: hasPricedUsage ? "USD" : "XXX",
            historyDays: days,
            historyCoverageIsEstablished: true,
            historyLabel: "Antigravity",
            costSource: .estimated,
            daily: daily,
            updatedAt: now)
    }

    // MARK: - Paths

    public static func antigravityHomeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let override = environment[self.homeEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity", isDirectory: true)
    }

    public static func conversationsURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        self.antigravityHomeURL(environment: environment)
            .appendingPathComponent("conversations", isDirectory: true)
    }

    private static func conversationDatabases(under directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else {
            return []
        }
        return contents
            .filter { $0.pathExtension == "db" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - SQLite

    private static func readRows(
        databaseURL: URL,
        pricing: (catalog: ModelsDevCatalog?, cacheRoot: URL?),
        seenResponseIDs: inout Set<String>,
        checkCancellation: () throws -> Void,
        onRow: (UsageRow) -> Void) throws
    {
        var db: OpaquePointer?
        // Observe committed WAL frames. `immutable=1` is unsafe for a live provider database
        // because SQLite may assume the WAL can never change and return stale history.
        let encodedPath = databaseURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? databaseURL.path
        let uri = "file:\(encodedPath)?mode=ro"
        guard sqlite3_open_v2(
            uri,
            &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX,
            nil) == SQLITE_OK
        else {
            sqlite3_close(db)
            throw ScanError.databaseUnavailable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        guard try self.hasTable(named: "gen_metadata", db: db) else { return }
        let sessionTimestampMs = (try? self.sessionCreatedMs(db: db)) ?? self.fileModifiedMs(databaseURL)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM gen_metadata ORDER BY idx", -1, &stmt, nil) == SQLITE_OK
        else { throw ScanError.databaseUnavailable }
        defer { sqlite3_finalize(stmt) }

        while true {
            try checkCancellation()
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ScanError.databaseUnavailable }
            guard let blob = self.columnBlob(stmt, 0) else { continue }
            if let row = self.parseGeneration(
                blob,
                sessionTimestampMs: sessionTimestampMs,
                catalog: pricing.catalog,
                cacheRoot: pricing.cacheRoot,
                seenResponseIDs: &seenResponseIDs)
            {
                onRow(row)
            }
        }
    }

    private static func parseGeneration(
        _ blob: [UInt8],
        sessionTimestampMs: Int64,
        catalog: ModelsDevCatalog?,
        cacheRoot: URL?,
        seenResponseIDs: inout Set<String>) -> UsageRow?
    {
        guard let chatModel = WireReader.messageField(blob, 1),
              let usage = WireReader.messageField(chatModel, 4)
        else {
            return nil
        }

        // Per-generation wall-clock time; fall back to the session-created stamp.
        let timestampMs = WireReader.messageField(chatModel, 9)
            .flatMap { WireReader.messageField($0, 4) }
            .flatMap { WireReader.timestampMs($0) }
            .flatMap { $0 > 0 ? $0 : nil }
            ?? sessionTimestampMs

        let inputPart1 = Self.clampedInt(WireReader.varintField(usage, 1))
        let inputPart2 = Self.clampedInt(WireReader.varintField(usage, 2))
        let inputAddition = inputPart1.addingReportingOverflow(inputPart2)
        guard !inputAddition.overflow else { return nil }
        let input = inputAddition.partialValue
        let cacheRead = Self.clampedInt(WireReader.varintField(usage, 5))
        let visibleOutput = Self.clampedInt(WireReader.varintField(usage, 9))
        let reasoning = Self.clampedInt(WireReader.varintField(usage, 10))
        let outputAddition = visibleOutput.addingReportingOverflow(reasoning)
        guard !outputAddition.overflow else { return nil }
        let output = outputAddition.partialValue
        guard input > 0 || output > 0 || cacheRead > 0 || reasoning > 0 else { return nil }

        if let responseID = WireReader.stringField(usage, 11)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !responseID.isEmpty
        {
            guard seenResponseIDs.insert(responseID).inserted else { return nil }
        }

        let modelRaw = WireReader.stringField(chatModel, 19)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = modelRaw.isEmpty ? "gemini" : modelRaw

        let costUSD = self.costUSD(
            model: model,
            tokens: TokenBuckets(input: input, cacheRead: cacheRead, output: output),
            catalog: catalog,
            cacheRoot: cacheRoot)

        return UsageRow(
            model: model,
            createdMs: timestampMs,
            input: input,
            cacheRead: cacheRead,
            output: output,
            reasoning: reasoning,
            responseID: nil,
            costUSD: costUSD)
    }

    // MARK: - Pricing

    private struct TokenBuckets {
        let input: Int
        let cacheRead: Int
        let output: Int
    }

    /// Prices a generation against its actual model provider. Known Gemini models use CodexBar's
    /// official Google pricing snapshot first and models.dev for newly released ids; Claude uses
    /// the same catalog-plus-bundled fallback as Claude Code. The raw display name is never changed.
    private static func costUSD(
        model: String,
        tokens: TokenBuckets,
        catalog: ModelsDevCatalog?,
        cacheRoot: URL?) -> Double?
    {
        let lowered = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.hasPrefix("claude-") {
            let pricingModel = self.claudePricingAliases[lowered] ?? lowered
            return CostUsagePricing.claudeCostUSD(
                model: pricingModel,
                inputTokens: tokens.input,
                cacheReadInputTokens: tokens.cacheRead,
                cacheCreationInputTokens: 0,
                outputTokens: tokens.output,
                modelsDevCatalog: catalog,
                modelsDevCacheRoot: cacheRoot)
        }
        return CostUsagePricing.googleCostUSD(
            model: lowered,
            inputTokens: tokens.input,
            cacheReadInputTokens: tokens.cacheRead,
            outputTokens: tokens.output,
            modelsDevCatalog: catalog,
            modelsDevCacheRoot: cacheRoot)
    }

    // MARK: - SQLite helpers

    private static func sessionCreatedMs(db: OpaquePointer?) throws -> Int64? {
        guard try self.hasTable(named: "trajectory_metadata_blob", db: db) else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM trajectory_metadata_blob LIMIT 1", -1, &stmt, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let blob = self.columnBlob(stmt, 0),
              let tsMessage = WireReader.messageField(blob, 2)
        else {
            return nil
        }
        return WireReader.timestampMs(tsMessage).flatMap { $0 > 0 ? $0 : nil }
    }

    private static func fileModifiedMs(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modified = values.contentModificationDate
        else {
            return 0
        }
        return Int64(modified.timeIntervalSince1970 * 1000)
    }

    private static func hasTable(named name: String, db: OpaquePointer?) throws -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            -1,
            &stmt,
            nil) == SQLITE_OK
        else {
            throw ScanError.databaseUnavailable
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, name, -1, transient)
        let step = sqlite3_step(stmt)
        if step == SQLITE_ROW { return true }
        if step == SQLITE_DONE { return false }
        throw ScanError.databaseUnavailable
    }

    private static func columnBlob(_ stmt: OpaquePointer?, _ index: Int32) -> [UInt8]? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard count > 0, let pointer = sqlite3_column_blob(stmt, index) else { return nil }
        let buffer = UnsafeRawBufferPointer(start: pointer, count: count)
        return Array(buffer)
    }

    private static func clampedInt(_ value: UInt64?) -> Int {
        guard let value else { return 0 }
        return Int(clamping: value)
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
}

// MARK: - Protobuf wire-format reader

/// Minimal dependency-free protobuf wire-format reader, mirroring tokscale's antigravity-cli
/// parser. Malformed data degrades to `nil`, never traps. Group wire types (3/4) are deprecated and
/// unsupported; encountering one stops the scan rather than risking desync.
private enum WireReader {
    enum Value {
        case varint(UInt64)
        case length([UInt8])
    }

    static func messageField(_ buffer: [UInt8], _ field: UInt64) -> [UInt8]? {
        for (number, value) in self.fields(buffer) where number == field {
            if case let .length(bytes) = value { return bytes }
        }
        return nil
    }

    static func varintField(_ buffer: [UInt8], _ field: UInt64) -> UInt64? {
        for (number, value) in self.fields(buffer) where number == field {
            if case let .varint(raw) = value { return raw }
        }
        return nil
    }

    static func stringField(_ buffer: [UInt8], _ field: UInt64) -> String? {
        guard let bytes = self.messageField(buffer, field) else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// Decode a `{#1: seconds, #2: nanos}` Timestamp to epoch milliseconds. Out-of-range nanos mark
    /// the stamp malformed; checked arithmetic keeps corrupt seconds from overflowing.
    static func timestampMs(_ buffer: [UInt8]) -> Int64? {
        guard let secondsRaw = self.varintField(buffer, 1),
              let seconds = Int64(exactly: secondsRaw)
        else {
            return nil
        }
        let nanosRaw = self.varintField(buffer, 2) ?? 0
        guard let nanos = Int64(exactly: nanosRaw), (0...999_999_999).contains(nanos) else { return nil }
        let millis = seconds.multipliedReportingOverflow(by: 1000)
        guard !millis.overflow else { return nil }
        let total = millis.partialValue.addingReportingOverflow(nanos / 1_000_000)
        return total.overflow ? nil : total.partialValue
    }

    private static func fields(_ buffer: [UInt8]) -> [(UInt64, Value)] {
        var result: [(UInt64, Value)] = []
        var position = 0
        while position < buffer.count {
            guard let tag = self.readVarint(buffer, &position) else { break }
            let field = tag >> 3
            switch tag & 0x7 {
            case 0:
                guard let value = self.readVarint(buffer, &position) else { return result }
                result.append((field, .varint(value)))
            case 1:
                guard position + 8 <= buffer.count else { return result }
                position += 8
            case 2:
                guard let length = self.readVarint(buffer, &position),
                      let count = Int(exactly: length),
                      count <= buffer.count - position
                else {
                    return result
                }
                result.append((field, .length(Array(buffer[position..<(position + count)]))))
                position += count
            case 5:
                guard position + 4 <= buffer.count else { return result }
                position += 4
            default:
                return result
            }
        }
        return result
    }

    private static func readVarint(_ buffer: [UInt8], _ position: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while position < buffer.count {
            let byte = buffer[position]
            position += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }
}
#endif
