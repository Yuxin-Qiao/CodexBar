import Foundation

extension CostUsageTokenSnapshot {
    /// Overlay only proven day growth while an in-scope Codex scan remains incomplete.
    /// Detailed project/session and event-time projections stay on their established report
    /// until full reconciliation; a partial daily total cannot prove their completeness.
    package func mergingMonotonicCheckpoint(
        _ checkpoint: CostUsageTokenSnapshot,
        now: Date,
        calendar: Calendar) -> CostUsageTokenSnapshot?
    {
        guard self.historyCoverageIsEstablished,
              !checkpoint.historyIsFullyScanned,
              self.historyDays == checkpoint.historyDays,
              self.currencyCode == checkpoint.currencyCode,
              self.credentialScopeFingerprint == checkpoint.credentialScopeFingerprint,
              checkpoint.updatedAt >= self.updatedAt
        else { return nil }
        var days = Dictionary(self.daily.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for entry in checkpoint.daily {
            guard let tokens = entry.totalTokens, tokens > 0,
                  tokens > (days[entry.date]?.totalTokens ?? 0),
                  Self.checkpointPreservesKnownMetrics(entry, prior: days[entry.date])
            else { continue }
            days[entry.date] = entry
            changed = true
        }
        guard changed else { return nil }
        let daily = days.values.sorted { $0.date < $1.date }
        let current = Self.entry(in: daily, forLocalDayContaining: now, calendar: calendar)
        let totalTokens = daily.allSatisfy { $0.totalTokens != nil }
            ? CheckedSum.integers(daily.compactMap(\.totalTokens)) : nil
        let totalCost = daily.allSatisfy { $0.costUSD != nil }
            ? daily.compactMap(\.costUSD).reduce(0, +) : nil
        let requests = daily.allSatisfy { $0.requestCount != nil }
            ? CheckedSum.integers(daily.compactMap(\.requestCount)) : nil
        var merged = CostUsageTokenSnapshot(
            sessionTokens: current?.totalTokens,
            sessionCostUSD: current?.costUSD,
            sessionRequests: current?.requestCount,
            last30DaysTokens: totalTokens,
            last30DaysCostUSD: totalCost,
            last30DaysRequests: requests,
            currencyCode: self.currencyCode,
            historyDays: self.historyDays,
            historyCoverageIsEstablished: true,
            historyScanIsPartial: true,
            historyLabel: self.historyLabel,
            meteredCostUSD: self.meteredCostUSD,
            costProvenance: self.costProvenance,
            credentialScopeFingerprint: self.credentialScopeFingerprint,
            daily: daily,
            projects: self.projects,
            sessions: self.sessions,
            hourly: self.hourly,
            quotaSlices: self.quotaSlices,
            updatedAt: checkpoint.updatedAt)
        merged.reportingPeriod = self.reportingPeriod
        return merged
    }

    private static func checkpointPreservesKnownMetrics(
        _ entry: CostUsageDailyReport.Entry,
        prior: CostUsageDailyReport.Entry?) -> Bool
    {
        guard let prior else { return true }
        if let oldCost = prior.costUSD {
            guard let cost = entry.costUSD, cost.isFinite, cost >= oldCost else { return false }
        }
        let metrics = [
            (prior.totalTokens, entry.totalTokens),
            (prior.inputTokens, entry.inputTokens),
            (prior.outputTokens, entry.outputTokens),
            (prior.cacheReadTokens, entry.cacheReadTokens),
            (prior.cacheCreationTokens, entry.cacheCreationTokens),
            (prior.reasoningTokens, entry.reasoningTokens),
            (prior.requestCount, entry.requestCount),
        ]
        return metrics.allSatisfy { old, new in
            guard let old else { return true }
            return new.map { $0 >= old } == true
        }
    }
}
