import Foundation

public enum KimiCodeSessionScanner {
    public static let defaultHistoryDays = 30

    public enum ScanError: Error, Equatable {
        /// The scan cannot claim complete history after omitting an otherwise eligible file.
        case historyLimitExceeded
        /// An existing session directory could not be enumerated.
        case enumerationFailed
    }

    public static let maximumFiles = 20000
    public static let maximumBytes = 512 * 1024 * 1024

    private struct WireEvent: Decodable {
        struct Usage: Decodable {
            let inputOther: Int?
            let inputCacheRead: Int?
            let inputCacheCreation: Int?
            let output: Int?
        }

        let type: String
        let time: Double?
        let model: String?
        let usage: Usage?
        let usageScope: String?
    }

    private struct DayModelKey: Hashable {
        let day: String
        let model: String
    }

    private struct TokenAccumulator {
        var input = 0
        var cacheRead = 0
        var cacheCreation = 0
        var output = 0
        var requests = 0
        var cost = 0.0
        var sawCost = false
        var sawUnpricedUsage = false

        mutating func add(
            _ usage: WireEvent.Usage,
            model: String,
            pricingDate: Date,
            modelsDevCatalog: ModelsDevCatalog?,
            modelsDevCacheRoot: URL?) -> Bool
        {
            guard let input = Self.valid(usage.inputOther),
                  let cacheRead = Self.valid(usage.inputCacheRead),
                  let cacheCreation = Self.valid(usage.inputCacheCreation),
                  let output = Self.valid(usage.output),
                  let nextInput = Self.adding(self.input, input),
                  let nextCacheRead = Self.adding(self.cacheRead, cacheRead),
                  let nextCacheCreation = Self.adding(self.cacheCreation, cacheCreation),
                  let nextOutput = Self.adding(self.output, output),
                  let nextRequests = Self.adding(self.requests, 1)
            else {
                return false
            }
            self.input = nextInput
            self.cacheRead = nextCacheRead
            self.cacheCreation = nextCacheCreation
            self.output = nextOutput
            self.requests = nextRequests
            if let cost = Self.estimatedCost(
                model: model,
                usage: usage,
                pricingDate: pricingDate,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot),
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

        mutating func merge(_ other: TokenAccumulator) -> Bool {
            guard let nextInput = Self.adding(self.input, other.input),
                  let nextCacheRead = Self.adding(self.cacheRead, other.cacheRead),
                  let nextCacheCreation = Self.adding(self.cacheCreation, other.cacheCreation),
                  let nextOutput = Self.adding(self.output, other.output),
                  let nextRequests = Self.adding(self.requests, other.requests)
            else {
                return false
            }
            self.input = nextInput
            self.cacheRead = nextCacheRead
            self.cacheCreation = nextCacheCreation
            self.output = nextOutput
            self.requests = nextRequests
            if other.sawCost {
                let nextCost = self.cost + other.cost
                if other.cost.isFinite, nextCost.isFinite {
                    self.cost = nextCost
                    self.sawCost = true
                }
            }
            if other.sawUnpricedUsage {
                self.sawUnpricedUsage = true
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

        private static func valid(_ value: Int?) -> Int? {
            guard let value, value >= 0 else { return nil }
            return value
        }

        private static func adding(_ lhs: Int, _ rhs: Int) -> Int? {
            let result = lhs.addingReportingOverflow(rhs)
            return result.overflow ? nil : result.partialValue
        }

        private static func estimatedCost(
            model: String,
            usage: WireEvent.Usage,
            pricingDate: Date,
            modelsDevCatalog: ModelsDevCatalog?,
            modelsDevCacheRoot: URL?) -> Double?
        {
            guard let input = self.valid(usage.inputOther),
                  let cacheRead = self.valid(usage.inputCacheRead),
                  let cacheCreation = self.valid(usage.inputCacheCreation),
                  let output = self.valid(usage.output)
            else {
                return nil
            }
            return CostUsagePricing.claudeCostUSD(
                model: self.pricingModelID(model),
                inputTokens: input,
                cacheReadInputTokens: cacheRead,
                cacheCreationInputTokens: cacheCreation,
                outputTokens: output,
                pricingDate: pricingDate,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot)
        }

        private static func pricingModelID(_ model: String) -> String {
            let bare = model.split(separator: "/", omittingEmptySubsequences: true).last
                .map(String.init) ?? model
            switch bare.lowercased() {
            case "k3", "k3-256k":
                return "kimi-k3"
            default:
                return bare
            }
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
        maximumFiles: Int = Self.maximumFiles,
        modelsDevCacheRoot: URL? = nil,
        checkCancellation: @escaping () throws -> Void = {}) throws -> CostUsageTokenSnapshot?
    {
        try checkCancellation()
        let days = max(1, historyDays)
        let calendar = CostUsageLocalDay.gregorianCalendar(preserving: calendar)
        let home = KimiSettingsReader.kimiCodeHomeURL(environment: environment)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        if !fileManager.fileExists(atPath: sessions.path) {
            return nil
        }
        guard let enumerator = fileManager.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else {
            throw ScanError.enumerationFailed
        }

        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        let decoder = JSONDecoder()
        let modelsDevCatalog = CostUsagePricing.modelsDevCatalog(now: now, cacheRoot: modelsDevCacheRoot)
        var scanContext = TranscriptScanContext(
            values: [:],
            decoder: decoder,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot,
            calendar: calendar,
            start: start,
            end: end,
            maximumFiles: maximumFiles)

        while let url = enumerator.nextObject() as? URL {
            try checkCancellation()
            try self.scanTranscript(url, context: &scanContext, checkCancellation: checkCancellation)
        }
        let values = scanContext.values

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
                    billingProviderID: UsageProvider.kimi.rawValue,
                    costUSD: value.sawCost && !value.sawUnpricedUsage ? value.cost : nil,
                    totalTokens: modelTotal,
                    inputTokens: value.input,
                    cacheReadTokens: value.cacheRead,
                    cacheCreationTokens: value.cacheCreation,
                    outputTokens: value.output,
                    requestCount: value.requests))
                if value.sawCost {
                    dayCost += value.cost
                    daySawCost = true
                }
                if value.sawUnpricedUsage {
                    dayHasUnpricedUsage = true
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
        // Day-level totals are withheld for mixed-price days; the aggregate is only published when
        // every contributing day has a complete cost, so a partial day never looks complete.
        let totalCost = !pricedDailyCosts.isEmpty && pricedDailyCosts.count == daily.count
            ? pricedDailyCosts.reduce(0, +)
            : nil
        guard let totalTokens, let totalRequests else { return nil }

        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            sessionRequests: nil,
            last30DaysTokens: totalTokens,
            last30DaysCostUSD: totalCost,
            last30DaysRequests: totalRequests,
            currencyCode: hasPricedUsage ? "USD" : "XXX",
            historyDays: days,
            historyCoverageIsEstablished: true,
            historyLabel: "Kimi Code CLI",
            costSource: .estimated,
            daily: daily,
            updatedAt: now)
    }

    private struct TranscriptScanContext {
        var values: [DayModelKey: TokenAccumulator]
        let decoder: JSONDecoder
        let modelsDevCatalog: ModelsDevCatalog?
        let modelsDevCacheRoot: URL?
        let calendar: Calendar
        let start: Date
        let end: Date
        let maximumFiles: Int
        var visitedFiles = 0
        var visitedBytes = 0
    }

    private static func scanTranscript(
        _ url: URL,
        context: inout TranscriptScanContext,
        checkCancellation: @escaping () throws -> Void) throws
    {
        var values = context.values
        let decoder = context.decoder
        let modelsDevCatalog = context.modelsDevCatalog
        let modelsDevCacheRoot = context.modelsDevCacheRoot
        let calendar = context.calendar
        let start = context.start
        let end = context.end
        let maximumFiles = context.maximumFiles
        var visitedFiles = context.visitedFiles
        var visitedBytes = context.visitedBytes
        guard url.lastPathComponent == "wire.jsonl",
              url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "agents"
        else {
            return
        }
        guard visitedFiles < maximumFiles else { throw ScanError.historyLimitExceeded }
        let resourceValues = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard resourceValues?.isRegularFile == true else { return }
        if let modificationDate = resourceValues?.contentModificationDate,
           modificationDate < start
        {
            return
        }
        let size = max(0, resourceValues?.fileSize ?? 0)
        guard size <= self.maximumBytes - visitedBytes else { throw ScanError.historyLimitExceeded }
        visitedFiles += 1
        visitedBytes += size
        context.visitedFiles = visitedFiles
        context.visitedBytes = visitedBytes
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
                guard let event = try? decoder.decode(WireEvent.self, from: line.bytes),
                      event.type == "usage.record",
                      event.usageScope == nil || event.usageScope == "turn",
                      let time = event.time,
                      time.isFinite,
                      let rawModel = event.model?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !rawModel.isEmpty,
                      let usage = event.usage
                else {
                    return
                }
                let date = Date(timeIntervalSince1970: time / 1000)
                let day = calendar.startOfDay(for: date)
                guard day >= start, day <= end else { return }
                let key = DayModelKey(
                    day: CostUsageLocalDay.key(from: day, calendar: calendar),
                    model: rawModel)
                var value = values[key] ?? TokenAccumulator()
                guard value.add(
                    usage,
                    model: rawModel,
                    pricingDate: date,
                    modelsDevCatalog: modelsDevCatalog,
                    modelsDevCacheRoot: modelsDevCacheRoot)
                else { return }
                values[key] = value
            }
            if sawTruncatedLine {
                throw ScanError.historyLimitExceeded
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch is ScanError {
            throw ScanError.historyLimitExceeded
        } catch {
            // A transiently unreadable transcript must surface as a failed scan instead of
            // silently publishing the remaining files as complete established history.
            throw error
        }
        context.values = values
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
