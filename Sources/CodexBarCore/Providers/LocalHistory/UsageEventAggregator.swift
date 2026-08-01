import Foundation

/// Shared aggregation engine for the local-history framework.
///
/// Every thin tool parser emits `UnifiedUsageEvent`s; this engine is the single place that turns
/// them into a dashboard-ready `CostUsageTokenSnapshot`. Centralizing the logic here is what
/// keeps per-tool adapters small and correct — the cached-prefix normalization, day/model
/// bucketing, models.dev pricing, and partial-pricing handling each exist exactly once instead of
/// being copied (and occasionally dropped) across scanners.
public enum UsageEventAggregator {
    /// Accumulates one (day, model) bucket.
    private struct Bucket {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheCreation = 0
        var reasoning = 0
        var requests = 0
        var cost = 0.0
        var sawCost = false
        /// Billing ownership evidence from the source record (per-model). Optional; falls back to
        /// the tool-level default when the source did not retain one.
        var billingProviderID: String?
        /// Set when a token-carrying event in this bucket could not be priced, so the merged day
        /// cost stays nil rather than presenting a partial subtotal as the complete total.
        var sawUnpricedUsage = false
        /// Set when at least one event in this bucket carried token usage. Buckets built only
        /// from degraded (model-only) events stay token-less.
        var sawTokenUsage = false

        var total: Int? {
            guard self.sawTokenUsage else { return nil }
            guard let inputAndCache = Self.adding(self.input, self.cacheRead) else { return nil }
            return Self.adding(inputAndCache, self.output)
        }

        fileprivate static func adding(_ lhs: Int, _ rhs: Int) -> Int? {
            let result = lhs.addingReportingOverflow(rhs)
            return result.overflow ? nil : result.partialValue
        }
    }

    private struct DayModelKey: Hashable {
        let day: String
        let model: String
    }

    /// Options that vary per tool rather than per event.
    public struct Options: Sendable {
        /// Display label for the snapshot (`historyLabel`), e.g. "ZCode".
        public var historyLabel: String
        /// Fallback billing owner written onto each model breakdown when an event did not carry
        /// its own `billingProviderID`.
        public var defaultBillingProviderID: String?
        /// `costSource` for the produced snapshot.
        public var costSource: CostUsageCostSource
        /// Root used to resolve the models.dev pricing catalog. Nil disables pricing.
        public var modelsDevCacheRoot: URL?

        public init(
            historyLabel: String,
            defaultBillingProviderID: String? = nil,
            costSource: CostUsageCostSource = .estimated,
            modelsDevCacheRoot: URL? = nil)
        {
            self.historyLabel = historyLabel
            self.defaultBillingProviderID = defaultBillingProviderID
            self.costSource = costSource
            self.modelsDevCacheRoot = modelsDevCacheRoot
        }
    }

    /// Aggregates a stream of events into a snapshot, or returns nil when there is nothing to
    /// report. `historyDays` is recorded on the snapshot; day-window filtering is the parser's
    /// responsibility (it knows each file's timestamps).
    ///
    /// Internal because it prices against the module-internal `ModelsDevCatalog`; tool scanners
    /// live in the same module, so this is the intended call surface.
    static func aggregate(
        events: [UnifiedUsageEvent],
        historyDays: Int,
        now: Date,
        options: Options) -> CostUsageTokenSnapshot?
    {
        let modelsDevCacheRoot = options.modelsDevCacheRoot
        let modelsDevCatalog = CostUsagePricing.modelsDevCatalog(now: now, cacheRoot: modelsDevCacheRoot)
        var buckets: [DayModelKey: Bucket] = [:]
        var order: [DayModelKey] = []
        for event in events {
            let key = DayModelKey(day: event.day, model: event.model)
            if buckets[key] == nil {
                buckets[key] = Bucket()
                order.append(key)
            }
            guard var bucket = buckets[key] else { continue }
            Self.add(event, to: &bucket, modelsDevCatalog: modelsDevCatalog, modelsDevCacheRoot: modelsDevCacheRoot)
            buckets[key] = bucket
        }
        guard !buckets.isEmpty else { return nil }

        let daily = Self.makeDaily(buckets: buckets, order: order, options: options)
        guard !daily.isEmpty else { return nil }

        let tokenEntries = daily.filter { $0.totalTokens != nil }
        let totalTokens = tokenEntries.isEmpty ? nil : Self.sum(tokenEntries.compactMap(\.totalTokens))
        let requests = tokenEntries.isEmpty ? nil : Self.sum(tokenEntries.compactMap(\.requestCount))
        // Publish the headline cost only when every token-bearing day is fully priced. A day whose
        // cost was withheld (mixed priced/unpriced usage) must not be silently dropped via
        // compactMap, or the remaining priced subtotal would masquerade as the complete total.
        let hasUnpricedTokenDay = daily.contains { $0.totalTokens != nil && $0.costUSD == nil }
        let costs = daily.compactMap(\.costUSD)
        let totalCost = (costs.isEmpty || hasUnpricedTokenDay) ? nil : costs.reduce(0, +)

        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: totalTokens,
            last30DaysCostUSD: totalCost,
            last30DaysRequests: requests,
            currencyCode: totalCost == nil ? "XXX" : "USD",
            historyDays: historyDays,
            historyCoverageIsEstablished: true,
            historyLabel: options.historyLabel,
            costSource: options.costSource,
            daily: daily,
            updatedAt: now)
    }

    /// Folds one event into its bucket, applying cached-prefix normalization and pricing.
    private static func add(
        _ event: UnifiedUsageEvent,
        to bucket: inout Bucket,
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?)
    {
        guard event.hasTokenUsage else { return }
        bucket.sawTokenUsage = true
        if bucket.billingProviderID == nil, let evidence = event.billingProviderID {
            bucket.billingProviderID = evidence
        }

        let rawInput = Self.valid(event.inputTokens)
        let output = Self.valid(event.outputTokens)
        let cacheRead = Self.valid(event.cacheReadTokens)
        let cacheCreation = Self.valid(event.cacheCreationTokens)
        let reasoning = Self.valid(event.reasoningTokens)
        // Reasoning is billed as output but is a sub-bucket of it; only add it when the source
        // reports output and reasoning separately (e.g. Gemini thoughts) rather than folded in.
        let billingOutput = output
        let uncachedInput = Self.uncachedInput(
            rawInput: rawInput,
            output: billingOutput,
            cacheRead: cacheRead,
            total: event.totalTokens)

        guard let nextInput = Bucket.adding(bucket.input, uncachedInput),
              let nextOutput = Bucket.adding(bucket.output, billingOutput),
              let nextCacheRead = Bucket.adding(bucket.cacheRead, cacheRead),
              let nextCacheCreation = Bucket.adding(bucket.cacheCreation, cacheCreation),
              let nextReasoning = Bucket.adding(bucket.reasoning, reasoning),
              let nextRequests = Bucket.adding(bucket.requests, max(1, event.requestCount ?? 1))
        else {
            return
        }
        bucket.input = nextInput
        bucket.output = nextOutput
        bucket.cacheRead = nextCacheRead
        bucket.cacheCreation = nextCacheCreation
        bucket.reasoning = nextReasoning
        bucket.requests = nextRequests

        if let providerCost = event.providerCostUSD, providerCost.isFinite {
            // The provider already priced this unit; trust it and do not re-price.
            let next = bucket.cost + providerCost
            if next.isFinite {
                bucket.cost = next
                bucket.sawCost = true
            }
            return
        }

        guard !event.pricingProviderIDs.isEmpty else {
            bucket.sawUnpricedUsage = true
            return
        }
        if let cost = CostUsagePricing.modelsDevCostUSD(
            request: .init(
                providerIDs: event.pricingProviderIDs,
                model: event.model,
                inputTokens: uncachedInput,
                cacheReadInputTokens: cacheRead,
                outputTokens: billingOutput,
                cacheCreationInputTokens: cacheCreation),
            catalog: modelsDevCatalog,
            cacheRoot: modelsDevCacheRoot),
            cost.isFinite
        {
            let next = bucket.cost + cost
            if next.isFinite {
                bucket.cost = next
                bucket.sawCost = true
            }
        } else {
            bucket.sawUnpricedUsage = true
        }
    }

    /// Splits a tool's reported input into its uncached remainder, cross-checking against the
    /// reported total the same way tokscale does: when `input + output == total` the input already
    /// includes the cached prefix; when `input + cacheRead + output == total` it is already
    /// uncached. Falls back to subtracting the cache when the total is missing or inconsistent.
    private static func uncachedInput(rawInput: Int, output: Int, cacheRead: Int, total: Int?) -> Int {
        guard let total else { return max(0, rawInput - cacheRead) }
        let inputPlusOutput = rawInput.addingReportingOverflow(output)
        let inputPlusCache = rawInput.addingReportingOverflow(cacheRead)
        let inputCachePlusOutput = inputPlusCache.overflow
            ? nil
            : inputPlusCache.partialValue.addingReportingOverflow(output)
        // Malformed records can carry counts near Int.max; overflow-reporting arithmetic lets the
        // aggregator reject the record instead of trapping inside these comparisons.
        if !inputPlusOutput.overflow, inputPlusOutput.partialValue == total {
            return max(0, rawInput - cacheRead)
        }
        if let inputCachePlusOutput, !inputCachePlusOutput.overflow,
           inputCachePlusOutput.partialValue == total
        {
            return rawInput
        }
        return max(0, rawInput - cacheRead)
    }

    private static func makeDaily(
        buckets: [DayModelKey: Bucket],
        order: [DayModelKey],
        options: Options) -> [CostUsageDailyReport.Entry]
    {
        let byDay = Dictionary(grouping: order, by: \.day)
        return byDay.keys.sorted().map { day in
            let dayKeys = (byDay[day] ?? []).sorted {
                $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending
            }
            var total = Bucket()
            var breakdowns: [CostUsageDailyReport.ModelBreakdown] = []
            var modelsUsed: [String] = []
            for key in dayKeys {
                guard let value = buckets[key] else { continue }
                modelsUsed.append(key.model)
                if value.sawTokenUsage {
                    breakdowns.append(CostUsageDailyReport.ModelBreakdown(
                        modelName: key.model,
                        billingProviderID: value.billingProviderID ?? options.defaultBillingProviderID,
                        costUSD: value.sawCost ? value.cost : nil,
                        totalTokens: value.total,
                        inputTokens: value.input,
                        cacheReadTokens: value.cacheRead,
                        cacheCreationTokens: value.cacheCreation,
                        outputTokens: value.output,
                        reasoningTokens: value.reasoning > 0 ? value.reasoning : nil,
                        requestCount: value.requests))
                }
                Self.merge(value, into: &total)
            }
            let dayCost = total.sawCost && !total.sawUnpricedUsage ? total.cost : nil
            let hasTokens = total.sawTokenUsage
            return CostUsageDailyReport.Entry(
                date: day,
                inputTokens: hasTokens ? total.input : nil,
                outputTokens: hasTokens ? total.output : nil,
                cacheReadTokens: hasTokens ? total.cacheRead : nil,
                cacheCreationTokens: hasTokens ? total.cacheCreation : nil,
                totalTokens: hasTokens ? total.total : nil,
                requestCount: hasTokens ? total.requests : nil,
                costUSD: dayCost,
                modelsUsed: modelsUsed.isEmpty ? nil : modelsUsed,
                modelBreakdowns: breakdowns.isEmpty ? nil : breakdowns)
        }
    }

    private static func merge(_ other: Bucket, into bucket: inout Bucket) {
        guard other.sawTokenUsage else { return }
        bucket.sawTokenUsage = true
        if let v = Bucket.adding(bucket.input, other.input) { bucket.input = v }
        if let v = Bucket.adding(bucket.output, other.output) { bucket.output = v }
        if let v = Bucket.adding(bucket.cacheRead, other.cacheRead) { bucket.cacheRead = v }
        if let v = Bucket.adding(bucket.cacheCreation, other.cacheCreation) { bucket.cacheCreation = v }
        if let v = Bucket.adding(bucket.reasoning, other.reasoning) { bucket.reasoning = v }
        if let v = Bucket.adding(bucket.requests, other.requests) { bucket.requests = v }
        if other.sawCost, other.cost.isFinite {
            let next = bucket.cost + other.cost
            if next.isFinite {
                bucket.cost = next
                bucket.sawCost = true
            }
        }
        bucket.sawUnpricedUsage = bucket.sawUnpricedUsage || other.sawUnpricedUsage
    }

    private static func valid(_ value: Int?) -> Int {
        guard let value, value >= 0 else { return 0 }
        return value
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
