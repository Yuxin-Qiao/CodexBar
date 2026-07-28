import CodexBarCore
import Foundation

extension SpendDashboardModel {
    struct ModelAnalysisAccumulator {
        var rawNames: Set<String> = []
        var displayNames: Set<String> = []
        var providerNames: [UsageProvider: String] = [:]
        var sourceContributions: [String: ModelAnalysisSourceAccumulator] = [:]
        var tokens: Int? = 0
        var inputTokens: Int? = 0
        var outputTokens: Int? = 0
        var cacheReadTokens: Int? = 0
        var cacheCreationTokens: Int? = 0
        var reasoningTokens: Int? = 0
        var requestCount: Int? = 0
        var cost: Double? = 0
        var sawTokens = false
        var sawTokenSplit = false
        var sawCacheReadTokens = false
        var missingCacheReadTokens = false
        var sawCacheCreationTokens = false
        var missingCacheCreationTokens = false
        var sawReasoningTokens = false
        var missingReasoningTokens = false
        var sawRequestCount = false
        var missingRequestCount = false
        var sawCost = false
        var sawEstimatedCost = false
        var invalidTokenSplit = false
        var overflowedTokens = false
        var overflowedInputTokens = false
        var overflowedOutputTokens = false
        var overflowedCacheReadTokens = false
        var overflowedCacheCreationTokens = false
        var overflowedReasoningTokens = false
        var overflowedRequestCount = false
        var overflowedCost = false
    }

    struct ModelAnalysisSourceAccumulator {
        let provider: UsageProvider
        let sourceName: String
        let providerName: String
        let coveredDayCount: Int
        let projectCount: Int?
        let sessionCount: Int?
        var rawNames: Set<String> = []
        var tokens: Int? = 0
        var inputTokens: Int? = 0
        var outputTokens: Int? = 0
        var cacheReadTokens: Int? = 0
        var cacheCreationTokens: Int? = 0
        var reasoningTokens: Int? = 0
        var requestCount: Int? = 0
        var cost: Double? = 0
        var sawTokens = false
        var sawTokenSplit = false
        var sawCacheReadTokens = false
        var missingCacheReadTokens = false
        var sawCacheCreationTokens = false
        var missingCacheCreationTokens = false
        var sawReasoningTokens = false
        var missingReasoningTokens = false
        var sawRequestCount = false
        var missingRequestCount = false
        var invalidTokenSplit = false
        var sawCost = false
        var overflowedTokens = false
        var overflowedInputTokens = false
        var overflowedOutputTokens = false
        var overflowedCacheReadTokens = false
        var overflowedCacheCreationTokens = false
        var overflowedReasoningTokens = false
        var overflowedRequestCount = false
        var overflowedCost = false
    }
}
