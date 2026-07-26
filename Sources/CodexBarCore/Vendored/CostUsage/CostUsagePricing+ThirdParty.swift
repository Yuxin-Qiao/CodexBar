import Foundation

extension CostUsagePricing {
    /// Resolves pricing for third-party models that are routed through the Claude-compatible
    /// endpoint (DeepSeek, Kimi/Moonshot, MiniMax) via the models.dev catalog.
    static func thirdPartyClaudeLookup(
        model: String,
        catalog: ModelsDevCatalog?,
        cacheRoot: URL?) -> ClaudePricing?
    {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        let candidates: [(providerID: String, modelID: String)]
        if lower.hasPrefix("deepseek-") {
            candidates = [("deepseek", trimmed)]
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
