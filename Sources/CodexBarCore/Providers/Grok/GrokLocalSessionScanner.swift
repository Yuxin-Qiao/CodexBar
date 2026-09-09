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
    private(set) var remaining: Int
    private(set) var isExhausted = false

    init(bytes: Int) {
        self.remaining = bytes
    }

    func consume(_ bytes: Int) {
        self.remaining = max(0, self.remaining - bytes)
    }

    func markExhausted() {
        self.isExhausted = true
    }
}

private struct GrokUsageRow {
    let date: Date
    let totalTokens: Int
    var models: Set<String>
}

private struct GrokUpdatesResult {
    var rows: [GrokUsageRow]
    let sawUsage: Bool
    let isComplete: Bool
}

private struct GrokSignalsSnapshot {
    let row: GrokUsageRow?
    let models: Set<String>
    let isComplete: Bool
}

private struct GrokDirectoryScan {
    let directory: URL
    var updates: GrokUpdatesResult
    var signals: GrokSignalsSnapshot?
}

struct GrokDiscoveredSessions {
    let directories: [URL]
    let enumerationFailed: Bool
    let discoveryCapped: Bool
}

/// Bounded file reading. Production reads through FileHandle with the given
/// limit; tests substitute a recording reader on the same wiring.
struct GrokBoundedReader {
    var read: (URL, Int) throws -> Data?

    static func live() -> Self {
        Self { url, limit in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            return try handle.read(upToCount: limit)
        }
    }
}

/// Lists candidate session directories. The live implementation walks the
/// filesystem and reports traversal errors; tests substitute a stub.
/// Resolved locally in scan(), never stored in Sendable options.
struct GrokSessionDirectoryEnumerator {
    var enumerate: (URL) throws -> GrokDiscoveredSessions

    static func live(
        fileManager: FileManager,
        maximumEntries: Int,
        checkCancellation: @escaping @Sendable () throws -> Void) -> Self
    {
        Self { root in
            var directories = Set<URL>()
            var directoriesWithUpdates = Set<URL>()
            var latestUpdatesMtimeByDirectory: [URL: Date] = [:]
            var latestSignalsMtimeByDirectory: [URL: Date] = [:]
            var enumerationFailed = false
            var discoveryCapped = false
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in
                    enumerationFailed = true
                    return true
                })
            else {
                return GrokDiscoveredSessions(
                    directories: [],
                    enumerationFailed: true,
                    discoveryCapped: false)
            }
            var entryCount = 0
            while let url = enumerator.nextObject() as? URL {
                try checkCancellation()
                entryCount += 1
                guard entryCount <= maximumEntries else {
                    discoveryCapped = true
                    break
                }
                guard url.lastPathComponent == "updates.jsonl" || url.lastPathComponent == "signals.json" else {
                    continue
                }
                let directory = url.deletingLastPathComponent()
                directories.insert(directory)
                let isUpdates = url.lastPathComponent == "updates.jsonl"
                if isUpdates {
                    directoriesWithUpdates.insert(directory)
                }
                let resourceValues = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .contentModificationDateKey])
                guard resourceValues?.isRegularFile == true else {
                    if url.lastPathComponent == "updates.jsonl" {
                        enumerationFailed = true
                    }
                    continue
                }
                if let modifiedAt = resourceValues?.contentModificationDate {
                    if isUpdates {
                        latestUpdatesMtimeByDirectory[directory] = max(
                            latestUpdatesMtimeByDirectory[directory] ?? .distantPast,
                            modifiedAt)
                    } else {
                        latestSignalsMtimeByDirectory[directory] = max(
                            latestSignalsMtimeByDirectory[directory] ?? .distantPast,
                            modifiedAt)
                    }
                }
            }
            // Structured update mtimes order directories that contain updates. A
            // signals mtime must not make an old, large updates file outrank a
            // newer structured file; signals-only directories use their own mtime
            // after every structured candidate. Whether a row counts is still
            // decided by its production timestamp. Candidates without metadata
            // sort after recent ones, deterministically by path.
            let ordered = directories.sorted { lhs, rhs in
                let leftHasUpdates = directoriesWithUpdates.contains(lhs)
                let rightHasUpdates = directoriesWithUpdates.contains(rhs)
                if leftHasUpdates != rightHasUpdates {
                    return leftHasUpdates
                }
                let leftMtime = leftHasUpdates
                    ? latestUpdatesMtimeByDirectory[lhs]
                    : latestSignalsMtimeByDirectory[lhs]
                let rightMtime = rightHasUpdates
                    ? latestUpdatesMtimeByDirectory[rhs]
                    : latestSignalsMtimeByDirectory[rhs]
                if let leftMtime, let rightMtime {
                    if leftMtime != rightMtime {
                        return leftMtime > rightMtime
                    }
                } else if leftMtime != nil {
                    return true
                } else if rightMtime != nil {
                    return false
                }
                return lhs.path < rhs.path
            }
            return GrokDiscoveredSessions(
                directories: ordered,
                enumerationFailed: enumerationFailed,
                discoveryCapped: discoveryCapped)
        }
    }
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
    static let maximumDiscoveredEntries = 50000
    private static let maximumUpdatesFileBytes = 8 * 1024 * 1024
    private static let maximumSignalsFileBytes = 1024 * 1024

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
        byteBudget: Int,
        sessionEnumerator: GrokSessionDirectoryEnumerator? = nil,
        boundedReader: GrokBoundedReader? = nil) -> GrokLocalSessionSummary
    {
        let options = GrokScanOptions(
            lookbackDays: lookbackDays,
            now: now,
            calendar: calendar,
            checkCancellation: {},
            byteBudget: byteBudget)
        return (try? self.scan(
            env: env,
            fileManager: fileManager,
            options: options,
            sessionEnumerator: sessionEnumerator,
            reader: boundedReader))
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
        options: GrokScanOptions,
        sessionEnumerator: GrokSessionDirectoryEnumerator? = nil,
        reader: GrokBoundedReader? = nil) throws -> GrokLocalSessionSummary
    {
        try options.checkCancellation()
        let root = GrokCredentialsStore.grokHomeURL(env: env, fileManager: fileManager)
            .appendingPathComponent("sessions", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return self.emptySummary(scannedAt: options.now)
        }
        let enumerator = sessionEnumerator ?? .live(
            fileManager: fileManager,
            maximumEntries: self.maximumDiscoveredEntries,
            checkCancellation: options.checkCancellation)
        let reader = reader ?? .live()

        var accumulator = GrokAccumulator(calendar: options.calendar)
        let discovered = try enumerator.enumerate(root)
        accumulator.isComplete = accumulator.isComplete && !discovered.enumerationFailed && !discovered.discoveryCapped

        // Read every structured usage file before spending the shared budget on
        // optional/lifetime metadata. A signals file can never replace a
        // structured update that was still readable in another directory.
        var directoryScans: [GrokDirectoryScan] = []
        for directory in discovered.directories {
            try options.checkCancellation()
            let updatesURL = directory.appendingPathComponent("updates.jsonl")
            let updates: GrokUpdatesResult
            if fileManager.fileExists(atPath: updatesURL.path) {
                guard self.isRegularFile(at: updatesURL) else {
                    updates = GrokUpdatesResult(rows: [], sawUsage: false, isComplete: false)
                    accumulator.isComplete = false
                    directoryScans.append(GrokDirectoryScan(directory: directory, updates: updates, signals: nil))
                    continue
                }
                updates = try self.readUpdates(at: updatesURL, options: options, reader: reader)
            } else {
                updates = GrokUpdatesResult(rows: [], sawUsage: false, isComplete: true)
            }
            accumulator.isComplete = accumulator.isComplete && updates.isComplete
            directoryScans.append(GrokDirectoryScan(directory: directory, updates: updates, signals: nil))
        }

        // A directory with no structured usage may be a legacy session, but a
        // readable modern updates file can also be empty before its first turn.
        // Only an actual legacy rollup or a signals read/parse failure should
        // downgrade coverage. Legacy values remain a lifetime context/compaction
        // approximation, not a daily consumption ledger.
        for index in directoryScans.indices where !directoryScans[index].updates.sawUsage {
            try options.checkCancellation()
            let updatesURL = directoryScans[index].directory.appendingPathComponent("updates.jsonl")
            let hasReadableUpdates = fileManager.fileExists(atPath: updatesURL.path)
                && self.isRegularFile(at: updatesURL)
            let signals = self.readSignals(
                at: directoryScans[index].directory.appendingPathComponent("signals.json"),
                fileManager: fileManager,
                budget: options.readBudget,
                reader: reader)
            directoryScans[index].signals = signals
            if !hasReadableUpdates || !signals.isComplete || signals.row != nil {
                accumulator.isComplete = false
            }
            if let row = signals.row, row.date >= options.cutoff, row.date <= options.now {
                accumulator.record(row)
            }
        }

        // Signals may provide a model label for a structured row that omitted
        // one. This is optional metadata: failure, truncation, or no remaining
        // budget must not invalidate otherwise complete token totals.
        for index in directoryScans.indices where directoryScans[index].updates.sawUsage {
            guard directoryScans[index].updates.rows.contains(where: \.models.isEmpty) else { continue }
            try options.checkCancellation()
            let signals = directoryScans[index].signals ?? self.readSignals(
                at: directoryScans[index].directory.appendingPathComponent("signals.json"),
                fileManager: fileManager,
                budget: options.readBudget,
                reader: reader)
            directoryScans[index].signals = signals
            guard !signals.models.isEmpty else { continue }
            directoryScans[index].updates.rows = directoryScans[index].updates.rows.map { row in
                guard row.models.isEmpty else { return row }
                var enriched = row
                enriched.models = signals.models
                return enriched
            }
        }

        for scan in directoryScans where scan.updates.sawUsage {
            for row in scan.updates.rows {
                accumulator.record(row)
            }
        }
        try options.checkCancellation()
        return accumulator.summary(scannedAt: options.now)
    }

    private static func readUpdates(
        at url: URL,
        options: GrokScanOptions,
        reader: GrokBoundedReader) throws -> GrokUpdatesResult
    {
        try options.checkCancellation()
        guard let data = self.readBoundedData(
            at: url,
            maximumBytes: self.maximumUpdatesFileBytes,
            budget: options.readBudget,
            reader: reader),
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
                meta["agentTimestampMs"] ?? meta["timestamp"] ?? paramsMeta["agentTimestampMs"] ?? json["ts"])
            else {
                isComplete = false
                continue
            }
            guard date >= options.cutoff, date <= options.now else { continue }
            if let sessionUpdate = update["sessionUpdate"] {
                guard let kind = self.nonEmptyString(sessionUpdate), kind == "turn_completed" else {
                    isComplete = false
                    continue
                }
            }
            if let incompleteValue = self.firstValue(
                in: usage,
                keys: ["usageIsIncomplete", "usage_is_incomplete"])
                ?? self.firstValue(in: update, keys: ["usageIsIncomplete", "usage_is_incomplete"])
            {
                guard let incomplete = self.strictBool(incompleteValue) else {
                    isComplete = false
                    continue
                }
                if incomplete {
                    isComplete = false
                }
            }
            guard let totalTokens = self.validatedUsageTotal(usage) else {
                isComplete = false
                continue
            }
            guard seenRows.insert(eventID.map { "event:\($0)" } ?? "row:\(line)").inserted else { continue }

            let usageModels = (usage["modelUsage"] as? [String: Any])?.keys
                .compactMap { self.nonEmptyString($0) } ?? []
            let models = usageModels.isEmpty
                ? currentModel.map { Set([$0]) } ?? []
                : Set(usageModels)
            rows.append(GrokUsageRow(date: date, totalTokens: totalTokens, models: models))
        }
        return GrokUpdatesResult(rows: rows, sawUsage: sawUsage, isComplete: isComplete)
    }

    private static func readSignals(
        at url: URL,
        fileManager: FileManager,
        budget: GrokReadBudget,
        reader: GrokBoundedReader) -> GrokSignalsSnapshot
    {
        guard fileManager.fileExists(atPath: url.path),
              self.isRegularFile(at: url),
              let data = self.readBoundedData(
                  at: url,
                  maximumBytes: self.maximumSignalsFileBytes,
                  budget: budget,
                  reader: reader),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            let exists = fileManager.fileExists(atPath: url.path)
            return GrokSignalsSnapshot(row: nil, models: [], isComplete: !exists)
        }

        var models = Set<String>()
        if let primary = self.nonEmptyString(json["primaryModelId"]) {
            models.insert(primary)
        }
        if let values = json["modelsUsed"] as? [String] {
            models.formUnion(values.compactMap { self.nonEmptyString($0) })
        }
        let hasTokenFields = json["totalTokensBeforeCompaction"] != nil
            || json["contextTokensUsed"] != nil
            || json["totalTokens"] != nil
        guard let beforeCompaction = self.optionalInteger(json["totalTokensBeforeCompaction"]),
              let contextUsed = self.optionalInteger(json["contextTokensUsed"] ?? json["totalTokens"])
        else {
            return GrokSignalsSnapshot(row: nil, models: models, isComplete: !hasTokenFields)
        }
        let (totalTokens, overflow) = beforeCompaction.addingReportingOverflow(contextUsed)
        guard !overflow else {
            return GrokSignalsSnapshot(row: nil, models: models, isComplete: false)
        }
        guard totalTokens > 0 else {
            return GrokSignalsSnapshot(row: nil, models: models, isComplete: true)
        }

        let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let date = self.parseDate(json["timestamp"] ?? json["ts"]) ?? modifiedAt
        let row = date.map { GrokUsageRow(date: $0, totalTokens: totalTokens, models: models) }
        return GrokSignalsSnapshot(row: row, models: models, isComplete: row != nil)
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

    private static func readBoundedData(
        at url: URL,
        maximumBytes: Int,
        budget: GrokReadBudget,
        reader: GrokBoundedReader) -> Data?
    {
        // No read once the shared budget is spent.
        guard budget.remaining > 0, !budget.isExhausted else {
            budget.markExhausted()
            return nil
        }
        // Pre-read allowance: remaining budget, never more than the cap+1 probe.
        let allowance = min(budget.remaining, maximumBytes + 1)
        guard let data = try? reader.read(url, allowance) else { return nil }
        budget.consume(data.count)
        // A short read proves EOF: the whole file fit in the allowance.
        if data.count < allowance {
            return data
        }
        // A full allowance read is only complete with a size proof of exact fit.
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard let fileSize, fileSize <= data.count, data.count <= maximumBytes else {
            if allowance < maximumBytes + 1 {
                budget.markExhausted()
            }
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

    private static func strictBool(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber else {
            return value as? Bool
        }
        guard String(cString: number.objCType) == "c" else { return nil }
        return number.boolValue
    }

    private static func asInt(_ value: Any) -> Int? {
        guard !self.isJSONBoolean(value) else { return nil }
        let parsed: Int? = if let number = value as? NSNumber {
            Int(number.stringValue)
        } else if let string = value as? String {
            Int(string)
        } else {
            nil
        }
        return parsed.flatMap { $0 >= 0 ? $0 : nil }
    }

    /// JSON booleans bridge to NSNumber on every platform, so `is Bool` would
    /// match all numbers. The ObjC type identifies real booleans ("c") instead.
    private static func isJSONBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else {
            return value is Bool
        }
        return String(cString: number.objCType) == "c"
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isRegularFile(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let value, !self.isJSONBoolean(value) else { return nil }
        let numeric = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        if let numeric, numeric.isFinite, numeric > 0 {
            return Date(timeIntervalSince1970: numeric < 10_000_000_000 ? numeric : numeric / 1000)
        }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}
