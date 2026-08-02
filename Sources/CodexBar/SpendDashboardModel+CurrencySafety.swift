import CodexBarCore
import Foundation

extension SpendDashboardModel.ModelAnalysis {
    func removingCosts(if shouldRemove: Bool) -> Self {
        guard shouldRemove else { return self }
        return Self(
            rows: self.rows.map { row in
                SpendDashboardModel.ModelAnalysisRow(
                    id: row.id,
                    displayName: row.displayName,
                    modelProvider: row.modelProvider,
                    rawModelNames: row.rawModelNames,
                    providers: row.providers,
                    providerNames: row.providerNames,
                    contributions: row.contributions.map { contribution in
                        SpendDashboardModel.ModelSourceContribution(
                            sourceID: contribution.sourceID,
                            provider: contribution.provider,
                            sourceName: contribution.sourceName,
                            providerName: contribution.providerName,
                            rawModelNames: contribution.rawModelNames,
                            totalTokens: contribution.totalTokens,
                            inputTokens: contribution.inputTokens,
                            outputTokens: contribution.outputTokens,
                            cacheReadTokens: contribution.cacheReadTokens,
                            cacheCreationTokens: contribution.cacheCreationTokens,
                            reasoningTokens: contribution.reasoningTokens,
                            requestCount: contribution.requestCount,
                            coveredDayCount: contribution.coveredDayCount,
                            projectCount: contribution.projectCount,
                            sessionCount: contribution.sessionCount,
                            estimatedCost: nil,
                            costIsEstimated: false)
                    },
                    totalTokens: row.totalTokens,
                    inputTokens: row.inputTokens,
                    outputTokens: row.outputTokens,
                    estimatedCost: nil,
                    cacheReadTokens: row.cacheReadTokens,
                    cacheCreationTokens: row.cacheCreationTokens,
                    reasoningTokens: row.reasoningTokens,
                    costIsEstimated: false)
            },
            dailyValues: self.dailyValues.map { value in
                SpendDashboardModel.ModelDailyValue(
                    modelID: value.modelID,
                    modelName: value.modelName,
                    day: value.day,
                    totalTokens: value.totalTokens,
                    inputTokens: value.inputTokens,
                    outputTokens: value.outputTokens,
                    estimatedCost: nil,
                    cacheReadTokens: value.cacheReadTokens,
                    cacheCreationTokens: value.cacheCreationTokens,
                    reasoningTokens: value.reasoningTokens)
            },
            trackedTokenTotal: self.trackedTokenTotal,
            pricedCostTotal: nil,
            sourceCount: self.sourceCount,
            tokenCoverage: self.tokenCoverage,
            costCoverage: .unavailable)
    }
}

extension SpendDashboardModel.CurrencyGroup {
    func removingCosts() -> Self {
        Self(
            currencyCode: self.currencyCode,
            providers: self.providers.map { row in
                SpendDashboardModel.ProviderRow(
                    id: row.id,
                    rank: row.rank,
                    provider: row.provider,
                    displayName: row.displayName,
                    subscriptionName: row.subscriptionName,
                    totalTokens: row.totalTokens,
                    totalCost: nil,
                    coveredDayCount: row.coveredDayCount)
            },
            models: self.models.map { row in
                SpendDashboardModel.ModelRow(
                    rank: row.rank,
                    provider: row.provider,
                    providerName: row.providerName,
                    modelName: row.modelName,
                    totalTokens: row.totalTokens,
                    totalCost: nil)
            },
            modelAnalysis: self.modelAnalysis.removingCosts(if: true),
            totalTokens: self.totalTokens,
            totalCost: nil,
            coveredDayCount: self.coveredDayCount,
            chartDomain: self.chartDomain,
            modelHistoryCompleteness: self.modelHistoryCompleteness)
    }

    var pricedProviderCount: Int {
        self.providers.count { $0.totalCost != nil }
    }

    var costCoverage: SpendDashboardModel.ModelMetricCoverage {
        guard !self.providers.isEmpty, self.pricedProviderCount > 0 else { return .unavailable }
        return self.pricedProviderCount == self.providers.count ? .complete : .partial
    }
}

extension SpendDashboardModel.ProviderInput {
    /// Returns a copy whose cost figures are pre-converted into the group's display currency by
    /// `multiplier`. Billing attribution merges inputs from different sources — and therefore from
    /// different original currencies — into a single vendor row, so the conversion must be baked in
    /// *before* attribution (after which a single multiplier of 1 applies). Token counts and other
    /// non-monetary fields pass through unchanged.
    func preMultipliedCosts(by multiplier: Double) -> Self {
        guard multiplier != 1 else { return self }
        let snapshot = self.snapshot
        let scaledDaily = snapshot.daily.map { entry in
            CostUsageDailyReport.Entry(
                date: entry.date,
                inputTokens: entry.inputTokens,
                outputTokens: entry.outputTokens,
                cacheReadTokens: entry.cacheReadTokens,
                cacheCreationTokens: entry.cacheCreationTokens,
                totalTokens: entry.totalTokens,
                requestCount: entry.requestCount,
                costUSD: entry.costUSD.map { $0 * multiplier },
                modelsUsed: entry.modelsUsed,
                modelBreakdowns: entry.modelBreakdowns?.map { breakdown in
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: breakdown.modelName,
                        billingProviderID: breakdown.billingProviderID,
                        costUSD: breakdown.costUSD.map { $0 * multiplier },
                        totalTokens: breakdown.totalTokens,
                        inputTokens: breakdown.inputTokens,
                        cacheReadTokens: breakdown.cacheReadTokens,
                        cacheCreationTokens: breakdown.cacheCreationTokens,
                        outputTokens: breakdown.outputTokens,
                        reasoningTokens: breakdown.reasoningTokens,
                        requestCount: breakdown.requestCount,
                        standardCostUSD: breakdown.standardCostUSD.map { $0 * multiplier },
                        priorityCostUSD: breakdown.priorityCostUSD.map { $0 * multiplier },
                        standardTokens: breakdown.standardTokens,
                        priorityTokens: breakdown.priorityTokens)
                })
        }
        let scaledSnapshot = CostUsageTokenSnapshot(
            sessionTokens: snapshot.sessionTokens,
            sessionCostUSD: snapshot.sessionCostUSD.map { $0 * multiplier },
            sessionRequests: snapshot.sessionRequests,
            last30DaysTokens: snapshot.last30DaysTokens,
            last30DaysCostUSD: snapshot.last30DaysCostUSD.map { $0 * multiplier },
            last30DaysRequests: snapshot.last30DaysRequests,
            currencyCode: snapshot.currencyCode,
            historyDays: snapshot.historyDays,
            historyCoverageIsEstablished: snapshot.historyCoverageIsEstablished,
            historyLabel: snapshot.historyLabel,
            meteredCostUSD: snapshot.meteredCostUSD.map { $0 * multiplier },
            costSource: snapshot.costSource,
            credentialScopeFingerprint: snapshot.credentialScopeFingerprint,
            daily: scaledDaily,
            projects: snapshot.projects,
            sessions: snapshot.sessions,
            updatedAt: snapshot.updatedAt)
        return SpendDashboardModel.ProviderInput(
            id: self.id,
            provider: self.provider,
            displayName: self.displayName,
            modelProviderName: self.modelProviderName,
            subscriptionName: self.subscriptionName,
            snapshot: scaledSnapshot)
    }
}
