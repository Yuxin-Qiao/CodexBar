/// Shared split-resolution state of the model-analysis accumulators.
protocol ModelTokenSplitAccumulating {
    var inputTokens: Int? { get }
    var outputTokens: Int? { get }
    var cacheReadTokens: Int? { get }
    var cacheCreationTokens: Int? { get }
    var reasoningTokens: Int? { get }
    var sawTokenSplit: Bool { get }
    var sawCacheReadTokens: Bool { get }
    var missingCacheReadTokens: Bool { get }
    var sawCacheCreationTokens: Bool { get }
    var missingCacheCreationTokens: Bool { get }
    var sawReasoningTokens: Bool { get }
    var missingReasoningTokens: Bool { get }
    var invalidTokenSplit: Bool { get }
    var overflowedInputTokens: Bool { get }
    var overflowedOutputTokens: Bool { get }
    var overflowedCacheReadTokens: Bool { get }
    var overflowedCacheCreationTokens: Bool { get }
    var overflowedReasoningTokens: Bool { get }
}

extension ModelTokenSplitAccumulating {
    func resolvedTokenBuckets() -> SpendDashboardModel.ModelTokenSplitBuckets {
        let hasCompleteTokenSplit = self.sawTokenSplit
            && !self.invalidTokenSplit
            && !self.overflowedInputTokens
            && !self.overflowedOutputTokens
        return SpendDashboardModel.ModelTokenSplitBuckets(
            inputTokens: hasCompleteTokenSplit ? self.inputTokens : nil,
            outputTokens: hasCompleteTokenSplit ? self.outputTokens : nil,
            cacheReadTokens: SpendDashboardModel.optionalTokenBucket(
                self.cacheReadTokens,
                saw: self.sawCacheReadTokens,
                missing: self.missingCacheReadTokens,
                overflowed: self.overflowedCacheReadTokens,
                splitIsComplete: hasCompleteTokenSplit),
            cacheCreationTokens: SpendDashboardModel.optionalTokenBucket(
                self.cacheCreationTokens,
                saw: self.sawCacheCreationTokens,
                missing: self.missingCacheCreationTokens,
                overflowed: self.overflowedCacheCreationTokens,
                splitIsComplete: hasCompleteTokenSplit),
            reasoningTokens: SpendDashboardModel.optionalTokenBucket(
                self.reasoningTokens,
                saw: self.sawReasoningTokens,
                missing: self.missingReasoningTokens,
                overflowed: self.overflowedReasoningTokens,
                splitIsComplete: hasCompleteTokenSplit))
    }
}

extension SpendDashboardModel.ModelAnalysisAccumulator: ModelTokenSplitAccumulating {}
extension SpendDashboardModel.ModelAnalysisDailyAccumulator: ModelTokenSplitAccumulating {}
