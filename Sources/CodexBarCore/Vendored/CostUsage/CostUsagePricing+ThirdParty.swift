import Foundation

extension CostUsagePricing {
    struct ModelsDevCostRequest {
        let providerIDs: [String]
        let model: String
        let inputTokens: Int
        let cacheReadInputTokens: Int
        let outputTokens: Int
        /// Cache-write (cache-creation) tokens. Defaults to 0 so callers that do not track them
        /// price unchanged; catalogs without a distinct cache-write rate fall back to the input
        /// rate, matching how cache reads are handled.
        var cacheCreationInputTokens: Int = 0
    }

    /// Prices a model against an explicit ordered list of models.dev provider IDs.
    ///
    /// Callers must supply provider ownership from structured source evidence. This helper never
    /// guesses a vendor from the model name, so a harness cannot silently bill usage to the wrong
    /// subscription.
    static func modelsDevCostUSD(
        request: ModelsDevCostRequest,
        catalog: ModelsDevCatalog?,
        cacheRoot: URL?) -> Double?
    {
        let lookup = request.providerIDs.lazy.compactMap {
            self.modelsDevLookup(
                providerID: $0,
                model: request.model,
                catalog: catalog,
                cacheRoot: cacheRoot)
        }.first
        guard let pricing = lookup?.pricing else { return nil }

        let input = max(0, request.inputTokens)
        let cacheRead = max(0, request.cacheReadInputTokens)
        let cacheCreation = max(0, request.cacheCreationInputTokens)
        let output = max(0, request.outputTokens)
        let context = input.addingReportingOverflow(cacheRead)
        let usesLongContextRates = pricing.thresholdTokens.map {
            context.overflow || context.partialValue > $0
        } ?? false
        let inputRate = usesLongContextRates
            ? pricing.inputCostPerTokenAboveThreshold ?? pricing.inputCostPerToken
            : pricing.inputCostPerToken
        let cacheReadRate = usesLongContextRates
            ? pricing.cacheReadInputCostPerTokenAboveThreshold
            ?? pricing.cacheReadInputCostPerToken
            ?? inputRate
            : pricing.cacheReadInputCostPerToken ?? inputRate
        let cacheCreationRate = usesLongContextRates
            ? pricing.cacheCreationInputCostPerTokenAboveThreshold
            ?? pricing.cacheCreationInputCostPerToken
            ?? inputRate
            : pricing.cacheCreationInputCostPerToken ?? inputRate
        let outputRate = usesLongContextRates
            ? pricing.outputCostPerTokenAboveThreshold ?? pricing.outputCostPerToken
            : pricing.outputCostPerToken
        let cost = Double(input) * inputRate
            + Double(cacheRead) * cacheReadRate
            + Double(cacheCreation) * cacheCreationRate
            + Double(output) * outputRate
        return cost.isFinite ? cost : nil
    }

    /// Resolves pricing for third-party models that are routed through the Claude-compatible
    /// endpoint (DeepSeek, Kimi/Moonshot, MiniMax) via the models.dev catalog.
    static func thirdPartyClaudeLookup(
        model: String,
        catalog: ModelsDevCatalog?,
        cacheRoot: URL?) -> ClaudePricing?
    {
        let routedModel = model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? model
        let trimmed = routedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        let candidates: [(providerID: String, modelID: String)]
        if lower.hasPrefix("deepseek-") {
            candidates = [("deepseek", trimmed)]
        } else if lower == "k3" || lower == "k3-256k" || lower == "kimi-k3" {
            candidates = [
                ("moonshotai", "kimi-k3"),
                ("moonshotai-cn", "kimi-k3"),
            ]
        } else if lower == "kimi-for-coding" {
            candidates = [
                ("kimi-for-coding", trimmed),
                ("moonshotai", "kimi-k2.6"),
                ("moonshotai-cn", "kimi-k2.6"),
            ]
        } else if lower.hasPrefix("kimi-") {
            candidates = [("moonshotai", trimmed), ("moonshotai-cn", trimmed)]
        } else if lower.hasPrefix("minimax-") {
            candidates = [("minimax", trimmed), ("minimax-cn", trimmed)]
        } else {
            return nil
        }

        for candidate in candidates {
            if let lookup = self.modelsDevLookup(
                providerID: candidate.providerID,
                model: candidate.modelID,
                catalog: catalog,
                cacheRoot: cacheRoot)
            {
                return ClaudePricing(
                    inputCostPerToken: lookup.pricing.inputCostPerToken,
                    outputCostPerToken: lookup.pricing.outputCostPerToken,
                    cacheCreationInputCostPerToken: lookup.pricing.cacheCreationInputCostPerToken
                        ?? lookup.pricing.inputCostPerToken,
                    cacheReadInputCostPerToken: lookup.pricing.cacheReadInputCostPerToken
                        ?? lookup.pricing.inputCostPerToken,
                    thresholdTokens: lookup.pricing.thresholdTokens,
                    inputCostPerTokenAboveThreshold: lookup.pricing.inputCostPerTokenAboveThreshold,
                    outputCostPerTokenAboveThreshold: lookup.pricing.outputCostPerTokenAboveThreshold,
                    cacheCreationInputCostPerTokenAboveThreshold: lookup.pricing
                        .cacheCreationInputCostPerTokenAboveThreshold,
                    cacheReadInputCostPerTokenAboveThreshold: lookup.pricing
                        .cacheReadInputCostPerTokenAboveThreshold)
            }
        }

        // Kimi's official API price on 2026-07-26 is $3/M uncached input, $0.30/M cached
        // input, and $15/M output for kimi-k3. Keep a fallback because newly released models can
        // precede the models.dev catalog; the catalog remains authoritative as soon as it contains
        // the model. Source: https://www.kimi.com/help/kimi-api/api-pricing
        if lower == "k3" || lower == "k3-256k" || lower == "kimi-k3" {
            return ClaudePricing(
                inputCostPerToken: 3 / 1_000_000,
                outputCostPerToken: 15 / 1_000_000,
                cacheCreationInputCostPerToken: 3 / 1_000_000,
                cacheReadInputCostPerToken: 0.30 / 1_000_000,
                thresholdTokens: nil,
                inputCostPerTokenAboveThreshold: nil,
                outputCostPerTokenAboveThreshold: nil,
                cacheCreationInputCostPerTokenAboveThreshold: nil,
                cacheReadInputCostPerTokenAboveThreshold: nil)
        }

        // MiniMax-M3 launched before every cached pricing catalog carried its pay-as-you-go row.
        // Keep the official standard-tier API price as a fallback so local Token Plan usage stays
        // priceable while offline or during catalog refresh. For requests whose input context
        // (including cache hits) exceeds 512K, MiniMax doubles input, output, and cache-read rates.
        // Source (accessed 2026-07-26):
        // https://platform.minimax.io/subscribe/token-plan?tab=api-enterprise
        if lower == "minimax-m3" {
            return ClaudePricing(
                inputCostPerToken: 0.30 / 1_000_000,
                outputCostPerToken: 1.20 / 1_000_000,
                cacheCreationInputCostPerToken: 0.30 / 1_000_000,
                cacheReadInputCostPerToken: 0.06 / 1_000_000,
                thresholdTokens: 512_000,
                inputCostPerTokenAboveThreshold: 0.60 / 1_000_000,
                outputCostPerTokenAboveThreshold: 2.40 / 1_000_000,
                cacheCreationInputCostPerTokenAboveThreshold: 0.60 / 1_000_000,
                cacheReadInputCostPerTokenAboveThreshold: 0.12 / 1_000_000)
        }
        return nil
    }

    static func modelsDevLookup(
        providerID: String,
        model: String,
        catalog: ModelsDevCatalog?,
        cacheRoot: URL?) -> ModelsDevPricingLookup?
    {
        if let catalog {
            return catalog.pricing(providerID: providerID, modelID: model)
        }

        return ModelsDevPricingPipeline.lookup(
            providerID: providerID,
            modelID: model,
            cacheRoot: cacheRoot)
    }
}
