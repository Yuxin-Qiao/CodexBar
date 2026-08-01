import Foundation

/// Reads Qwen Code's local JSONL history.
///
/// Qwen stores assistant messages under `~/.qwen/projects/*/chats/*.jsonl`.
/// The format is also consumed by tokscale. The scanner is deliberately
/// bounded and cancellable so enabling a long history cannot turn dashboard
/// refresh into an unbounded filesystem crawl.
public enum QwenCodeSessionScanner {
    public static let homeEnvironmentKey = "QWEN_HOME"
    public static let defaultHistoryDays = 30
    public static let maximumFiles = 20000
    public static let maximumBytes = 512 * 1024 * 1024

    public enum ScanError: Error, Equatable {
        /// The scan cannot claim complete history after omitting an otherwise eligible record.
        case historyLimitExceeded
    }

    private struct WireMessage: Decodable {
        struct Usage: Decodable {
            let promptTokenCount: Int?
            let candidatesTokenCount: Int?
            let thoughtsTokenCount: Int?
            let cachedContentTokenCount: Int?
        }

        let type: String?
        let model: String?
        let timestamp: String?
        let usageMetadata: Usage?
    }

    private struct DayModelKey: Hashable {
        let day: String
        let model: String
    }

    private struct TokenAccumulator {
        var input = 0
        var output = 0
        var cacheRead = 0
        var reasoning = 0
        var requests = 0
        var cost = 0.0
        var sawCost = false
        /// Set when at least one message in this accumulator carried billable usage but had no
        /// resolvable price. The merged day/entry cost must then stay nil so the dashboard does not
        /// present a partial subtotal as the complete day total.
        var sawUnpricedUsage = false

        mutating func add(
            usage: WireMessage.Usage,
            model: String,
            modelsDevCatalog: ModelsDevCatalog?,
            modelsDevCacheRoot: URL?) -> Bool
        {
            // Gemini-style `promptTokenCount` already includes the cached prefix
            // (`cachedContentTokenCount` is a subset of it). Passing the full prompt as input AND the
            // cached portion again as cache-read would bill the cached tokens twice, so split the
            // prompt into its uncached remainder.
            guard let promptTotal = Self.valid(usage.promptTokenCount),
                  let candidates = Self.valid(usage.candidatesTokenCount),
                  let reasoning = Self.valid(usage.thoughtsTokenCount),
                  let cacheRead = Self.valid(usage.cachedContentTokenCount),
                  let billingOutput = Self.adding(candidates, reasoning)
            else {
                return false
            }
            let uncachedInput = max(0, promptTotal - cacheRead)
            guard let nextInput = Self.adding(self.input, uncachedInput),
                  let nextOutput = Self.adding(self.output, billingOutput),
                  let nextCacheRead = Self.adding(self.cacheRead, cacheRead),
                  let nextReasoning = Self.adding(self.reasoning, reasoning),
                  let nextRequests = Self.adding(self.requests, 1)
            else {
                return false
            }
            guard promptTotal > 0 || billingOutput > 0 || cacheRead > 0 else { return false }
            self.input = nextInput
            self.output = nextOutput
            self.cacheRead = nextCacheRead
            self.reasoning = nextReasoning
            self.requests = nextRequests
            if let cost = CostUsagePricing.modelsDevCostUSD(
                request: .init(
                    providerIDs: ["alibaba", "alibaba-cn"],
                    model: model,
                    inputTokens: uncachedInput,
                    cacheReadInputTokens: cacheRead,
                    outputTokens: billingOutput),
                catalog: modelsDevCatalog,
                cacheRoot: modelsDevCacheRoot),
                cost.isFinite
            {
                let nextCost = self.cost + cost
                if nextCost.isFinite {
                    self.cost = nextCost
                    self.sawCost = true
                }
            } else {
                self.sawUnpricedUsage = true
            }
            return true
        }

        mutating func merge(_ other: Self) -> Bool {
            guard let input = Self.adding(self.input, other.input),
                  let output = Self.adding(self.output, other.output),
                  let cacheRead = Self.adding(self.cacheRead, other.cacheRead),
                  let reasoning = Self.adding(self.reasoning, other.reasoning),
                  let requests = Self.adding(self.requests, other.requests)
            else {
                return false
            }
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.reasoning = reasoning
            self.requests = requests
            if other.sawCost {
                let nextCost = self.cost + other.cost
                if other.cost.isFinite, nextCost.isFinite {
                    self.cost = nextCost
                    self.sawCost = true
                }
            }
            self.sawUnpricedUsage = self.sawUnpricedUsage || other.sawUnpricedUsage
            return true
        }

        var total: Int? {
            guard let inputAndCache = Self.adding(self.input, self.cacheRead) else { return nil }
            return Self.adding(inputAndCache, self.output)
        }

        private static func valid(_ value: Int?) -> Int? {
            guard let value, value >= 0 else { return 0 }
            return value
        }

        private static func adding(_ lhs: Int, _ rhs: Int) -> Int? {
            let result = lhs.addingReportingOverflow(rhs)
            return result.overflow ? nil : result.partialValue
        }
    }

    public static func scan(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        historyDays: Int = defaultHistoryDays,
        now: Date = Date(),
        calendar: Calendar = .current,
        modelsDevCacheRoot: URL? = nil) -> CostUsageTokenSnapshot?
    {
        try? self.scanCancellable(
            environment: environment,
            fileManager: fileManager,
            historyDays: historyDays,
            now: now,
            calendar: calendar,
            modelsDevCacheRoot: modelsDevCacheRoot)
    }

    public static func scanCancellable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        historyDays: Int = defaultHistoryDays,
        now: Date = Date(),
        calendar: Calendar = .current,
        modelsDevCacheRoot: URL? = nil,
        checkCancellation: @escaping () throws -> Void = {}) throws -> CostUsageTokenSnapshot?
    {
        try checkCancellation()
        let days = max(1, historyDays)
        let calendar = CostUsageLocalDay.gregorianCalendar(preserving: calendar)
        let home = self.homeURL(environment: environment)
        let root = home.appendingPathComponent("projects", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else {
            return nil
        }

        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        let decoder = JSONDecoder()
        // Qwen emits both whole-second and fractional-second RFC 3339 timestamps. The default
        // formatter rejects fractional seconds and would silently collapse those messages onto the
        // file's modification day, so try a fractional-seconds formatter first.
        let iso8601Fractional = ISO8601DateFormatter()
        iso8601Fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso8601 = ISO8601DateFormatter()
        let parseTimestamp: (String) -> Date? = { raw in
            iso8601Fractional.date(from: raw) ?? iso8601.date(from: raw)
        }
        let modelsDevCatalog = CostUsagePricing.modelsDevCatalog(now: now, cacheRoot: modelsDevCacheRoot)
        var values: [DayModelKey: TokenAccumulator] = [:]
        var visitedFiles = 0
        var visitedBytes = 0

        while let url = enumerator.nextObject() as? URL {
            try checkCancellation()
            guard url.pathExtension.lowercased() == "jsonl",
                  url.deletingLastPathComponent().lastPathComponent == "chats"
            else {
                continue
            }
            guard visitedFiles < self.maximumFiles else { throw ScanError.historyLimitExceeded }
            let resourceValues = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard resourceValues?.isRegularFile == true else { continue }
            if let modified = resourceValues?.contentModificationDate, modified < start {
                continue
            }
            let size = max(0, resourceValues?.fileSize ?? 0)
            guard size <= self.maximumBytes - visitedBytes else { throw ScanError.historyLimitExceeded }
            visitedFiles += 1
            visitedBytes += size

            var sawTruncatedLine = false
            do {
                try CostUsageJsonl.scan(
                    fileURL: url,
                    maxLineBytes: 1024 * 1024,
                    prefixBytes: 1024 * 1024,
                    checkCancellation: checkCancellation)
                { line in
                    guard !line.wasTruncated else {
                        sawTruncatedLine = true
                        return
                    }
                    guard let message = try? decoder.decode(WireMessage.self, from: line.bytes),
                          message.type == "assistant",
                          let usage = message.usageMetadata
                    else {
                        return
                    }
                    let eventDate = message.timestamp.flatMap(parseTimestamp)
                        ?? resourceValues?.contentModificationDate
                        ?? now
                    let eventDay = calendar.startOfDay(for: eventDate)
                    guard eventDay >= start, eventDay <= end else { return }
                    let model = message.model?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalizedModel = model?.isEmpty == false ? model! : "unknown"
                    let key = DayModelKey(
                        day: CostUsageLocalDay.key(from: eventDay, calendar: calendar),
                        model: normalizedModel)
                    var accumulator = values[key] ?? TokenAccumulator()
                    guard accumulator.add(
                        usage: usage,
                        model: normalizedModel,
                        modelsDevCatalog: modelsDevCatalog,
                        modelsDevCacheRoot: modelsDevCacheRoot)
                    else {
                        return
                    }
                    values[key] = accumulator
                }
                if sawTruncatedLine {
                    throw ScanError.historyLimitExceeded
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch is ScanError {
                throw ScanError.historyLimitExceeded
            } catch {
                continue
            }
        }

        guard !values.isEmpty else { return nil }
        let daily = self.makeDaily(values: values)
        guard let totalTokens = self.sum(daily.compactMap(\.totalTokens)),
              let requests = self.sum(daily.compactMap(\.requestCount))
        else {
            return nil
        }
        let pricedDailyCosts = daily.compactMap(\.costUSD)
        let hasPricedUsage = daily.contains { entry in
            entry.modelBreakdowns?.contains { $0.costUSD != nil } == true
        }
        let totalCost = pricedDailyCosts.count == daily.count
            ? pricedDailyCosts.reduce(0, +)
            : nil
        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: totalTokens,
            last30DaysCostUSD: totalCost,
            last30DaysRequests: requests,
            currencyCode: hasPricedUsage ? "USD" : "XXX",
            historyDays: days,
            historyCoverageIsEstablished: true,
            historyLabel: "Qwen Code CLI",
            costSource: .estimated,
            daily: daily,
            updatedAt: now)
    }

    public static func homeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let override = environment[self.homeEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qwen", isDirectory: true)
    }

    private static func makeDaily(values: [DayModelKey: TokenAccumulator])
        -> [CostUsageDailyReport.Entry]
    {
        let byDay = Dictionary(grouping: values, by: \.key.day)
        return byDay.keys.sorted().compactMap { day in
            let models = (byDay[day] ?? []).sorted {
                $0.key.model.localizedCaseInsensitiveCompare($1.key.model) == .orderedAscending
            }
            var total = TokenAccumulator()
            var breakdowns: [CostUsageDailyReport.ModelBreakdown] = []
            for (key, value) in models {
                guard let modelTotal = value.total, total.merge(value) else { return nil }
                breakdowns.append(CostUsageDailyReport.ModelBreakdown(
                    modelName: key.model,
                    billingProviderID: UsageProvider.qwencloud.rawValue,
                    costUSD: value.sawCost ? value.cost : nil,
                    totalTokens: modelTotal,
                    inputTokens: value.input,
                    cacheReadTokens: value.cacheRead,
                    cacheCreationTokens: 0,
                    outputTokens: value.output,
                    reasoningTokens: value.reasoning,
                    requestCount: value.requests))
            }
            guard let dayTotal = total.total else { return nil }
            // Withhold the day cost whenever any contributing model could not be priced, so the
            // dashboard treats the day as partially priced instead of a confident complete total.
            let dayCost = total.sawCost && !total.sawUnpricedUsage ? total.cost : nil
            return CostUsageDailyReport.Entry(
                date: day,
                inputTokens: total.input,
                outputTokens: total.output,
                cacheReadTokens: total.cacheRead,
                cacheCreationTokens: 0,
                totalTokens: dayTotal,
                requestCount: total.requests,
                costUSD: dayCost,
                modelsUsed: breakdowns.map(\.modelName),
                modelBreakdowns: breakdowns)
        }
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
