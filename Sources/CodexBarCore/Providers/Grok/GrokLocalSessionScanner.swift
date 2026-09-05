import Foundation

/// One local-calendar day of Grok session-token activity.
public struct GrokLocalDailyBucket: Sendable, Equatable {
    public let date: String
    public let totalTokens: Int
    public let models: [String]

    public init(date: String, totalTokens: Int, models: [String]) {
        self.date = date
        self.totalTokens = totalTokens
        self.models = models
    }
}

/// Aggregated stats from local Grok Build session history.
public struct GrokLocalSessionSummary: Sendable {
    public let totalTokens: Int
    public let daily: [GrokLocalDailyBucket]
    public let scannedAt: Date
    public let historyCoverageIsEstablished: Bool

    public init(
        totalTokens: Int,
        daily: [GrokLocalDailyBucket] = [],
        historyCoverageIsEstablished: Bool = true,
        scannedAt: Date = .init())
    {
        self.totalTokens = totalTokens
        self.daily = daily
        self.historyCoverageIsEstablished = historyCoverageIsEstablished
        self.scannedAt = scannedAt
    }

    /// Local tokens only. A session is not a request, and subscription credits are not dollars.
    public func toCostUsageTokenSnapshot(
        historyDays: Int,
        calendar: Calendar = .current) -> CostUsageTokenSnapshot
    {
        let entries = self.daily.map {
            CostUsageDailyReport.Entry(
                date: $0.date,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: $0.totalTokens,
                requestCount: nil,
                costUSD: nil,
                modelsUsed: $0.models.isEmpty ? nil : $0.models,
                modelBreakdowns: nil)
        }
        let today = GrokLocalSessionScanner.dayKey(for: self.scannedAt, calendar: calendar)
            .flatMap { key in entries.first { $0.date == key }?.totalTokens }
        let knownZero = self.historyCoverageIsEstablished ? 0 : nil
        return CostUsageTokenSnapshot(
            sessionTokens: today ?? knownZero,
            sessionCostUSD: nil,
            sessionRequests: nil,
            last30DaysTokens: entries.isEmpty ? knownZero : self.totalTokens,
            last30DaysCostUSD: nil,
            last30DaysRequests: nil,
            historyDays: historyDays,
            historyCoverageIsEstablished: self.historyCoverageIsEstablished,
            costProvenance: .unknown,
            daily: entries,
            updatedAt: self.scannedAt)
    }
}

private struct GrokScanOptions: Sendable {
    let now: Date
    let cutoff: Date
    let calendar: Calendar
    let checkCancellation: @Sendable () throws -> Void
    let readBudget: GrokReadBudget

    init(
        lookbackDays: Int,
        now: Date,
        calendar: Calendar,
        checkCancellation: @escaping @Sendable () throws -> Void,
        byteBudget: Int = GrokLocalSessionScanner.defaultTotalReadBytes)
    {
        self.now = now
        self.calendar = calendar
        self.checkCancellation = checkCancellation
        self.readBudget = GrokReadBudget(bytes: byteBudget)
        let today = calendar.startOfDay(for: now)
        self.cutoff = calendar.date(byAdding: .day, value: -(max(1, lookbackDays) - 1), to: today) ?? today
    }
}

/// Shared cap on bytes read during one refresh. Touched serially by the scan loop.
private final class GrokReadBudget: @unchecked Sendable {
    private var remaining: Int
    private(set) var isExhausted = false

    init(bytes: Int) {
        self.remaining = bytes
    }

    /// Consumes the bytes actually read. Returns false without consuming when the
    /// read would exceed what remains, and latches `isExhausted` so later reads stop.
    func consume(_ bytes: Int) -> Bool {
        guard bytes <= self.remaining else {
            self.isExhausted = true
            return false
        }
        self.remaining -= bytes
        return true
    }
}

private struct GrokUsageRow {
    let date: Date
    let totalTokens: Int
    let models: Set<String>
}

private struct GrokUpdatesResult {
    let rows: [GrokUsageRow]
    let sawUsage: Bool
    let isComplete: Bool
}

private struct GrokSignalsSnapshot {
    let row: GrokUsageRow?
    let models: Set<String>
}

private struct GrokDayAccumulator {
    var totalTokens = 0
    var models = Set<String>()
}

private struct GrokAccumulator {
    let calendar: Calendar
    var days: [String: GrokDayAccumulator] = [:]
    var totalTokens = 0
    var isComplete = true

    mutating func record(_ row: GrokUsageRow) {
        guard row.totalTokens > 0,
              let dayKey = GrokLocalSessionScanner.dayKey(for: row.date, calendar: self.calendar)
        else { return }

        var day = self.days[dayKey] ?? GrokDayAccumulator()
        let (nextTotal, totalOverflow) = self.totalTokens.addingReportingOverflow(row.totalTokens)
        let (nextDayTotal, dayOverflow) = day.totalTokens.addingReportingOverflow(row.totalTokens)
        guard !totalOverflow, !dayOverflow else {
            self.isComplete = false
            return
        }

        self.totalTokens = nextTotal
        day.totalTokens = nextDayTotal
        day.models.formUnion(row.models)
        self.days[dayKey] = day
    }

    func summary(scannedAt: Date) -> GrokLocalSessionSummary {
        let daily = self.days.keys.sorted().compactMap { key -> GrokLocalDailyBucket? in
            guard let day = self.days[key] else { return nil }
            return GrokLocalDailyBucket(
                date: key,
                totalTokens: day.totalTokens,
                models: day.models.sorted())
        }
        return GrokLocalSessionSummary(
            totalTokens: self.totalTokens,
            daily: daily,
            historyCoverageIsEstablished: self.isComplete,
            scannedAt: scannedAt)
    }
}

public enum GrokLocalSessionScanner {
    public static let defaultLookbackDays = 30
    static let defaultTotalReadBytes = 64 * 1024 * 1024
    private static let maximumUpdatesFileBytes = 8 * 1024 * 1024
    private static let maximumSignalsFileBytes = 1024 * 1024
    private static let maximumDiscoveredEntries = 50000

    public static func summarize(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        lookbackDays: Int = defaultLookbackDays,
        now: Date = .init(),
        calendar: Calendar = .current) -> GrokLocalSessionSummary
    {
        let options = GrokScanOptions(
            lookbackDays: lookbackDays,
            now: now,
            calendar: calendar,
            checkCancellation: {})
        return (try? self.scan(env: env, fileManager: fileManager, options: options))
            ?? self.emptySummary(scannedAt: now)
    }

    /// Test seam: same scan with an injectable shared read budget.
    static func summarize(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        lookbackDays: Int = defaultLookbackDays,
        now: Date = .init(),
        calendar: Calendar = .current,
        byteBudget: Int) -> GrokLocalSessionSummary
    {
        let options = GrokScanOptions(
            lookbackDays: lookbackDays,
            now: now,
            calendar: calendar,
            checkCancellation: {},
            byteBudget: byteBudget)
        return (try? self.scan(env: env, fileManager: fileManager, options: options))
            ?? self.emptySummary(scannedAt: now)
    }

    public static func summarizeOffMainThread(
        env: [String: String],
        lookbackDays: Int = defaultLookbackDays,
        now: Date = .init(),
        calendar: Calendar = .current) async throws -> GrokLocalSessionSummary
    {
        try await CostUsageScanExecutor.run { checkCancellation in
            let options = GrokScanOptions(
                lookbackDays: lookbackDays,
                now: now,
                calendar: calendar,
                checkCancellation: checkCancellation)
            return try self.scan(env: env, options: options)
        }
    }

    private static func scan(
        env: [String: String],
        fileManager: FileManager = .default,
        options: GrokScanOptions) throws -> GrokLocalSessionSummary
    {
        try options.checkCancellation()
        let root = GrokCredentialsStore.grokHomeURL(env: env, fileManager: fileManager)
            .appendingPathComponent("sessions", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = fileManager.enumerator(
                  at: root,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles])
        else {
            return self.emptySummary(scannedAt: options.now)
        }

        var accumulator = GrokAccumulator(calendar: options.calendar)
        var directories = Set<URL>()
        var entryCount = 0
        while let url = enumerator.nextObject() as? URL {
            try options.checkCancellation()
            entryCount += 1
            guard entryCount <= self.maximumDiscoveredEntries else {
                accumulator.isComplete = false
                break
            }
            guard url.lastPathComponent == "updates.jsonl" || url.lastPathComponent == "signals.json" else {
                continue
            }
            directories.insert(url.deletingLastPathComponent())
        }

        for directory in directories.sorted(by: { $0.path < $1.path }) {
            try options.checkCancellation()
            guard !options.readBudget.isExhausted else {
                accumulator.isComplete = false
                break
            }
            let signals = self.readSignals(
                at: directory.appendingPathComponent("signals.json"),
                fileManager: fileManager,
                budget: options.readBudget)
            let updatesURL = directory.appendingPathComponent("updates.jsonl")
            let updates = fileManager.fileExists(atPath: updatesURL.path)
                ? try self.readUpdates(
                    at: updatesURL,
                    fallbackModels: signals.models,
                    options: options)
                : GrokUpdatesResult(rows: [], sawUsage: false, isComplete: true)
            accumulator.isComplete = accumulator.isComplete && updates.isComplete

            if updates.sawUsage {
                for row in updates.rows {
                    accumulator.record(row)
                }
            } else {
                // signals.json is a lifetime rollup; file time cannot prove daily coverage.
                accumulator.isComplete = false
                if let row = signals.row, row.date >= options.cutoff, row.date <= options.now {
                    accumulator.record(row)
                }
            }
        }
        try options.checkCancellation()
        return accumulator.summary(scannedAt: options.now)
    }

    private static func readUpdates(
        at url: URL,
        fallbackModels: Set<String>,
        options: GrokScanOptions) throws -> GrokUpdatesResult
    {
        try options.checkCancellation()
        guard let data = self.readBoundedData(
            at: url,
            maximumBytes: self.maximumUpdatesFileBytes,
            budget: options.readBudget),
            let content = String(data: data, encoding: .utf8)
        else {
            return GrokUpdatesResult(rows: [], sawUsage: false, isComplete: false)
        }

        var rows: [GrokUsageRow] = []
        var currentModel: String?
        var sawUsage = false
        var isComplete = true
        var seenRows = Set<String>()
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            try options.checkCancellation()
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                isComplete = false
                continue
            }

            let meta = (json["_meta"] as? [String: Any]) ?? (json["meta"] as? [String: Any]) ?? [:]
            let params = (json["params"] as? [String: Any]) ?? [:]
            let paramsMeta = (params["_meta"] as? [String: Any]) ?? [:]
            if let model = self.nonEmptyString(meta["modelId"] ?? paramsMeta["modelId"]) {
                currentModel = model
            }
            guard let update = params["update"] as? [String: Any],
                  let usage = update["usage"] as? [String: Any]
            else { continue }
            sawUsage = true
            let eventID = self.nonEmptyString(meta["eventId"] ?? paramsMeta["eventId"])
            guard let date = self.parseDate(
                meta["agentTimestampMs"] ?? meta["timestamp"] ?? paramsMeta["agentTimestampMs"] ?? json["ts"]),
                let totalTokens = self.validatedUsageTotal(usage)
            else {
                isComplete = false
                continue
            }
            guard seenRows.insert(eventID.map { "event:\($0)" } ?? "row:\(line)").inserted else { continue }
            guard date >= options.cutoff, date <= options.now else { continue }

            let usageModels = (usage["modelUsage"] as? [String: Any])?.keys
                .compactMap { self.nonEmptyString($0) } ?? []
            let models = usageModels.isEmpty
                ? currentModel.map { Set([$0]) } ?? fallbackModels
                : Set(usageModels)
            rows.append(GrokUsageRow(date: date, totalTokens: totalTokens, models: models))
        }
        return GrokUpdatesResult(rows: rows, sawUsage: sawUsage, isComplete: isComplete)
    }

    private static func readSignals(at url: URL, fileManager: FileManager, budget: GrokReadBudget)
        -> GrokSignalsSnapshot
    {
        guard fileManager.fileExists(atPath: url.path),
              let data = self.readBoundedData(at: url, maximumBytes: self.maximumSignalsFileBytes, budget: budget),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return GrokSignalsSnapshot(row: nil, models: [])
        }

        var models = Set<String>()
        if let primary = self.nonEmptyString(json["primaryModelId"]) {
            models.insert(primary)
        }
        if let values = json["modelsUsed"] as? [String] {
            models.formUnion(values.compactMap { self.nonEmptyString($0) })
        }
        guard let beforeCompaction = self.optionalInteger(json["totalTokensBeforeCompaction"]),
              let contextUsed = self.optionalInteger(json["contextTokensUsed"] ?? json["totalTokens"])
        else {
            return GrokSignalsSnapshot(row: nil, models: models)
        }
        let (totalTokens, overflow) = beforeCompaction.addingReportingOverflow(contextUsed)
        guard !overflow, totalTokens > 0 else {
            return GrokSignalsSnapshot(row: nil, models: models)
        }

        let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let date = self.parseDate(json["timestamp"] ?? json["ts"]) ?? modifiedAt
        let row = date.map { GrokUsageRow(date: $0, totalTokens: totalTokens, models: models) }
        return GrokSignalsSnapshot(row: row, models: models)
    }

    private static func validatedUsageTotal(_ usage: [String: Any]) -> Int? {
        guard let input = self.firstInteger(in: usage, keys: ["inputTokens", "promptTokens", "input_tokens"]),
              let output = self.firstInteger(in: usage, keys: ["outputTokens", "completionTokens", "output_tokens"])
        else { return nil }
        let (total, overflow) = input.addingReportingOverflow(output)
        guard !overflow else { return nil }
        if let reported = self.firstValue(in: usage, keys: ["totalTokens", "total_tokens"]) {
            guard self.asInt(reported) == total else { return nil }
        }
        return total
    }

    private static func readBoundedData(at url: URL, maximumBytes: Int, budget: GrokReadBudget) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes + 1),
              budget.consume(data.count),
              data.count <= maximumBytes
        else {
            return nil
        }
        return data
    }

    private static func emptySummary(scannedAt: Date) -> GrokLocalSessionSummary {
        GrokLocalSessionSummary(
            totalTokens: 0,
            historyCoverageIsEstablished: false,
            scannedAt: scannedAt)
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String? {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func firstValue(in values: [String: Any], keys: [String]) -> Any? {
        keys.lazy.compactMap { values[$0] }.first
    }

    private static func firstInteger(in values: [String: Any], keys: [String]) -> Int? {
        self.firstValue(in: values, keys: keys).flatMap(self.asInt)
    }

    private static func optionalInteger(_ value: Any?) -> Int? {
        guard let value else { return 0 }
        return self.asInt(value)
    }

    private static func asInt(_ value: Any) -> Int? {
        guard CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        let parsed: Int? = if let number = value as? NSNumber {
            Int(number.stringValue)
        } else if let string = value as? String {
            Int(string)
        } else {
            nil
        }
        return parsed.flatMap { $0 >= 0 ? $0 : nil }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let value, CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        let numeric = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        if let numeric, numeric.isFinite, numeric > 0 {
            return Date(timeIntervalSince1970: numeric < 10_000_000_000 ? numeric : numeric / 1000)
        }
        guard let string = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }
}
