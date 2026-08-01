import Foundation

/// Reads ZCode's local JSONL rollout history.
///
/// ZCode stores one file per session under `~/.zcode/cli/rollout/model-io-sess_*.jsonl`. Each
/// line is a single billable request with `completedAt` (RFC 3339), `model.modelId` (e.g.
/// `GLM-5.2`), `model.providerId` (e.g. `builtin:bigmodel-start-plan`, the Zhipu/BigModel coding
/// plan), and `response.usage` carrying `inputTokens`, `outputTokens`, `totalTokens`,
/// `cacheReadTokens`, and `cacheWriteTokens`.
///
/// ZCode's `inputTokens` already includes the cached prefix, mirroring tokscale's zcode handling:
/// `inputTokens + outputTokens == totalTokens` even when `cacheReadTokens > 0`. We therefore
/// cross-check against `totalTokens` and split the prompt into its uncached remainder so cached
/// tokens are never billed twice. Usage is priced at the vendor's official Z.ai API rate (the
/// coding-plan catalog entries are zero-priced because the plan is a flat subscription); only
/// when no official rate is known does the day stay partially priced.
public enum ZcodeSessionScanner {
    public static let homeEnvironmentKey = "ZCODE_HOME"
    public static let defaultHistoryDays = 30
    public static let maximumFiles = 20000
    public static let maximumBytes = 512 * 1024 * 1024

    private struct WireMessage: Decodable {
        struct Model: Decodable {
            let modelId: String?
            let providerId: String?
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let totalTokens: Int?
            let cacheReadTokens: Int?
            let cacheWriteTokens: Int?
        }

        struct Response: Decodable {
            let usage: Usage?
        }

        let completedAt: String?
        let model: Model?
        let response: Response?
    }

    private struct DayModelKey: Hashable {
        let day: String
        let model: String
    }

    private struct TokenAccumulator {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        var requests = 0
        var cost = 0.0
        var sawCost = false
        /// Set when at least one request in this accumulator carried billable usage but had no
        /// resolvable price. The merged day/entry cost then stays nil so the dashboard does not
        /// present a partial subtotal as the complete day total.
        var sawUnpricedUsage = false

        mutating func add(
            usage: WireMessage.Usage,
            model: String,
            modelsDevCatalog: ModelsDevCatalog?,
            modelsDevCacheRoot: URL?) -> Bool
        {
            guard let rawInput = Self.valid(usage.inputTokens),
                  let output = Self.valid(usage.outputTokens),
                  let cacheRead = Self.valid(usage.cacheReadTokens),
                  let cacheWrite = Self.valid(usage.cacheWriteTokens),
                  let total = Self.valid(usage.totalTokens)
            else {
                return false
            }
            // Normalize the cached-prefix double count. When `input + output == total` the input
            // already includes the cached prefix, so the billable uncached input is
            // `input - cacheRead`. When `input + cacheRead + output == total` the input is already
            // uncached. Fall back to subtracting the cache when total is inconsistent.
            let uncachedInput: Int = if let inputPlusOutput = Self.adding(rawInput, output), inputPlusOutput == total {
                max(0, rawInput - cacheRead)
            } else if let withCache = Self.adding(rawInput, cacheRead),
                      let withCacheAndOutput = Self.adding(withCache, output),
                      withCacheAndOutput == total
            {
                rawInput
            } else {
                max(0, rawInput - cacheRead)
            }
            guard let nextInput = Self.adding(self.input, uncachedInput),
                  let nextOutput = Self.adding(self.output, output),
                  let nextCacheRead = Self.adding(self.cacheRead, cacheRead),
                  let nextCacheWrite = Self.adding(self.cacheWrite, cacheWrite),
                  let nextRequests = Self.adding(self.requests, 1)
            else {
                return false
            }
            guard uncachedInput > 0 || output > 0 || cacheRead > 0 else { return false }
            self.input = nextInput
            self.output = nextOutput
            self.cacheRead = nextCacheRead
            self.cacheWrite = nextCacheWrite
            self.requests = nextRequests
            // Price at the official Z.ai API rate (zhipuai is the same vendor's alias). The
            // `zai-coding-plan`/`zhipuai-coding-plan` catalogs are intentionally excluded: they are
            // zero-priced flat subscriptions, and we report the API-equivalent value to stay
            // consistent with how other subscription tools are estimated.
            if let cost = CostUsagePricing.modelsDevCostUSD(
                request: .init(
                    providerIDs: ["zai", "zhipuai"],
                    model: model,
                    inputTokens: uncachedInput,
                    cacheReadInputTokens: cacheRead,
                    outputTokens: output),
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
                  let cacheWrite = Self.adding(self.cacheWrite, other.cacheWrite),
                  let requests = Self.adding(self.requests, other.requests)
            else {
                return false
            }
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
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
        let root = self.homeURL(environment: environment)
            .appendingPathComponent("cli", isDirectory: true)
            .appendingPathComponent("rollout", isDirectory: true)
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
        // ZCode emits RFC 3339 timestamps with fractional seconds (`2026-06-14T17:23:26.382Z`).
        // The whole-second formatter rejects them, so try the fractional variant first.
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
                  url.lastPathComponent.hasPrefix("model-io-sess")
            else {
                continue
            }
            guard visitedFiles < self.maximumFiles else { break }
            let resourceValues = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard resourceValues?.isRegularFile == true else { continue }
            if let modified = resourceValues?.contentModificationDate, modified < start {
                continue
            }
            let size = max(0, resourceValues?.fileSize ?? 0)
            guard size <= self.maximumBytes - visitedBytes else { break }
            visitedFiles += 1
            visitedBytes += size

            do {
                try CostUsageJsonl.scan(
                    fileURL: url,
                    maxLineBytes: 1024 * 1024,
                    prefixBytes: 1024 * 1024,
                    checkCancellation: checkCancellation)
                { line in
                    guard !line.wasTruncated,
                          let message = try? decoder.decode(WireMessage.self, from: line.bytes),
                          let usage = message.response?.usage
                    else {
                        return
                    }
                    let eventDate = message.completedAt.flatMap(parseTimestamp)
                        ?? resourceValues?.contentModificationDate
                        ?? now
                    let eventDay = calendar.startOfDay(for: eventDate)
                    guard eventDay >= start, eventDay <= end else { return }
                    // models.dev keys the Z.ai catalog by the lowercase model id (`glm-5.2`), while
                    // ZCode records the display casing (`GLM-5.2`).
                    let model = message.model?.modelId?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalizedModel = model?.isEmpty == false
                        ? model!.lowercased()
                        : "unknown"
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
            } catch is CancellationError {
                throw CancellationError()
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
        let costs = daily.compactMap(\.costUSD)
        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: totalTokens,
            last30DaysCostUSD: costs.isEmpty ? nil : costs.reduce(0, +),
            last30DaysRequests: requests,
            currencyCode: costs.isEmpty ? "XXX" : "USD",
            historyDays: days,
            historyCoverageIsEstablished: true,
            historyLabel: "ZCode",
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
            .appendingPathComponent(".zcode", isDirectory: true)
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
                    billingProviderID: UsageProvider.zai.rawValue,
                    costUSD: value.sawCost ? value.cost : nil,
                    totalTokens: modelTotal,
                    inputTokens: value.input,
                    cacheReadTokens: value.cacheRead,
                    cacheCreationTokens: value.cacheWrite,
                    outputTokens: value.output,
                    reasoningTokens: 0,
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
                cacheCreationTokens: total.cacheWrite,
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
