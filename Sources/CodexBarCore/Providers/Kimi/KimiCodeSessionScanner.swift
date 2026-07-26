import Foundation

public enum KimiCodeSessionScanner {
    public static let defaultHistoryDays = 30

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
                modelsDevCacheRoot: modelsDevCacheRoot)
            {
                self.cost += cost
                self.sawCost = true
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
                self.cost += other.cost
                self.sawCost = true
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
        let days = max(1, historyDays)
        let home = KimiSettingsReader.kimiCodeHomeURL(environment: environment)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else {
            return nil
        }

        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        var values: [DayModelKey: TokenAccumulator] = [:]
        let decoder = JSONDecoder()
        let modelsDevCatalog = CostUsagePricing.modelsDevCatalog(now: now, cacheRoot: modelsDevCacheRoot)

        while let url = enumerator.nextObject() as? URL {
            guard url.lastPathComponent == "wire.jsonl",
                  url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "agents"
            else {
                continue
            }
            if let modificationDate = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate,
                modificationDate < start
            {
                continue
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard let event = try? decoder.decode(WireEvent.self, from: Data(line)),
                      event.type == "usage.record",
                      event.usageScope == "turn",
                      let time = event.time,
                      time.isFinite,
                      let rawModel = event.model?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !rawModel.isEmpty,
                      let usage = event.usage
                else {
                    continue
                }
                let date = Date(timeIntervalSince1970: time / 1000)
                let day = calendar.startOfDay(for: date)
                guard day >= start, day <= end else { continue }
                let key = DayModelKey(day: CostUsageLocalDay.key(from: day, calendar: calendar), model: rawModel)
                var value = values[key] ?? TokenAccumulator()
                guard value.add(
                    usage,
                    model: rawModel,
                    pricingDate: date,
                    modelsDevCatalog: modelsDevCatalog,
                    modelsDevCacheRoot: modelsDevCacheRoot)
                else { continue }
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
            for (key, value) in models {
                guard let modelTotal = value.total else { return nil }
                guard total.merge(value) else { return nil }
                modelBreakdowns.append(CostUsageDailyReport.ModelBreakdown(
                    modelName: key.model,
                    costUSD: value.sawCost ? value.cost : nil,
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
                costUSD: daySawCost ? dayCost : nil,
                modelsUsed: modelBreakdowns.map(\.modelName),
                modelBreakdowns: modelBreakdowns)
        }
        let totalTokens = self.sum(daily.compactMap(\.totalTokens))
        let totalRequests = self.sum(daily.compactMap(\.requestCount))
        let totalCost = daily.compactMap(\.costUSD).reduce(0, +)
        let sawCost = daily.contains { $0.costUSD != nil }
        guard let totalTokens, let totalRequests else { return nil }

        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            sessionRequests: nil,
            last30DaysTokens: totalTokens,
            last30DaysCostUSD: sawCost ? totalCost : nil,
            last30DaysRequests: totalRequests,
            currencyCode: sawCost ? "USD" : "XXX",
            historyDays: days,
            historyCoverageIsEstablished: true,
            historyLabel: "Kimi Code CLI",
            costSource: .estimated,
            daily: daily,
            updatedAt: now)
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
