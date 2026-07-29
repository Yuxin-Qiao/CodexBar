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
            dailyPoints: [],
            dailySpendDetails: [],
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
