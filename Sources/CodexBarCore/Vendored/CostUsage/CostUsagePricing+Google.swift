import Foundation

extension CostUsagePricing {
    private struct GooglePricing {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheReadInputCostPerToken: Double
        let thresholdTokens: Int?
        let inputCostPerTokenAboveThreshold: Double?
        let outputCostPerTokenAboveThreshold: Double?
        let cacheReadInputCostPerTokenAboveThreshold: Double?
    }

    /// Official Google Gemini Standard rates, kept as an offline fallback for model ids that can
    /// appear in Antigravity before the cached models.dev catalog catches up.
    ///
    /// Source (accessed 2026-07-28):
    /// https://ai.google.dev/gemini-api/docs/pricing
    private static let google: [String: GooglePricing] = [
        "gemini-3.6-flash": GooglePricing(
            inputCostPerToken: 1.50 / 1_000_000,
            outputCostPerToken: 7.50 / 1_000_000,
            cacheReadInputCostPerToken: 0.15 / 1_000_000,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "gemini-3.5-flash": GooglePricing(
            inputCostPerToken: 1.50 / 1_000_000,
            outputCostPerToken: 9.00 / 1_000_000,
            cacheReadInputCostPerToken: 0.15 / 1_000_000,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "gemini-3.1-pro-preview": GooglePricing(
            inputCostPerToken: 2.00 / 1_000_000,
            outputCostPerToken: 12.00 / 1_000_000,
            cacheReadInputCostPerToken: 0.20 / 1_000_000,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 4.00 / 1_000_000,
            outputCostPerTokenAboveThreshold: 18.00 / 1_000_000,
            cacheReadInputCostPerTokenAboveThreshold: 0.40 / 1_000_000),
        "gemini-3-flash-preview": GooglePricing(
            inputCostPerToken: 0.50 / 1_000_000,
            outputCostPerToken: 3.00 / 1_000_000,
            cacheReadInputCostPerToken: 0.05 / 1_000_000,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
    ]

    private static let googleAliases: [String: String] = [
        "gemini-pro-default": "gemini-3.1-pro-preview",
        "gemini-pro-agent": "gemini-3.1-pro-preview",
        "gemini-3.1-pro": "gemini-3.1-pro-preview",
        "gemini-3.1-pro-high": "gemini-3.1-pro-preview",
        "gemini-3.1-pro-low": "gemini-3.1-pro-preview",
        "gemini-3-flash": "gemini-3-flash-preview",
        "gemini-3-flash-c": "gemini-3-flash-preview",
        "gemini-default": "gemini-3-flash-preview",
        "gemini-3-flash-a": "gemini-3.5-flash",
        "gemini-3-flash-agent": "gemini-3.5-flash",
        "gemini-3-flash-b": "gemini-3.5-flash",
        "gemini-3.5-flash-high": "gemini-3.5-flash",
        "gemini-3.5-flash-medium": "gemini-3.5-flash",
        "gemini-3.5-flash-low": "gemini-3.5-flash",
        "gemini-3.5-flash-extra-low": "gemini-3.5-flash",
    ]

    static func googleCostUSD(
        model: String,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        outputTokens: Int,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil) -> Double?
    {
        let canonicalModel = self.googlePricingModelID(model)
        // Prefer the refreshed models.dev catalog so a corrected or updated rate is actually used;
        // the embedded table below is the offline fallback for ids the catalog has not caught up
        // with yet, not the first source consulted.
        if let lookup = self.modelsDevLookup(
            providerID: "google",
            model: canonicalModel,
            catalog: modelsDevCatalog,
            cacheRoot: modelsDevCacheRoot)
        {
            return self.googleCostUSD(
                pricing: lookup.pricing,
                inputTokens: inputTokens,
                cacheReadInputTokens: cacheReadInputTokens,
                outputTokens: outputTokens)
        }

        guard let pricing = self.google[canonicalModel] else { return nil }
        return self.googleCostUSD(
            pricing: pricing,
            inputTokens: inputTokens,
            cacheReadInputTokens: cacheReadInputTokens,
            outputTokens: outputTokens)
    }

    static func googlePricingModelID(_ model: String) -> String {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return self.googleAliases[normalized] ?? normalized
    }

    private static func googleCostUSD(
        pricing: ModelsDevPricingInfo,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        outputTokens: Int) -> Double
    {
        let input = max(0, inputTokens)
        let cacheRead = max(0, cacheReadInputTokens)
        let output = max(0, outputTokens)
        let totalInput = input.addingReportingOverflow(cacheRead)
        let usesLongContextRates = pricing.thresholdTokens.map {
            totalInput.overflow || totalInput.partialValue > $0
        } ?? false
        let inputRate = usesLongContextRates
            ? pricing.inputCostPerTokenAboveThreshold ?? pricing.inputCostPerToken
            : pricing.inputCostPerToken
        let cacheReadRate = usesLongContextRates
            ? pricing.cacheReadInputCostPerTokenAboveThreshold
            ?? pricing.cacheReadInputCostPerToken
            ?? inputRate
            : pricing.cacheReadInputCostPerToken ?? inputRate
        let outputRate = usesLongContextRates
            ? pricing.outputCostPerTokenAboveThreshold ?? pricing.outputCostPerToken
            : pricing.outputCostPerToken
        return Double(input) * inputRate
            + Double(cacheRead) * cacheReadRate
            + Double(output) * outputRate
    }

    private static func googleCostUSD(
        pricing: GooglePricing,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        outputTokens: Int) -> Double
    {
        let input = max(0, inputTokens)
        let cacheRead = max(0, cacheReadInputTokens)
        let output = max(0, outputTokens)
        let totalInput = input.addingReportingOverflow(cacheRead)
        let usesLongContextRates = pricing.thresholdTokens.map {
            totalInput.overflow || totalInput.partialValue > $0
        } ?? false
        let inputRate = usesLongContextRates
            ? pricing.inputCostPerTokenAboveThreshold ?? pricing.inputCostPerToken
            : pricing.inputCostPerToken
        let cacheReadRate = usesLongContextRates
            ? pricing.cacheReadInputCostPerTokenAboveThreshold ?? pricing.cacheReadInputCostPerToken
            : pricing.cacheReadInputCostPerToken
        let outputRate = usesLongContextRates
            ? pricing.outputCostPerTokenAboveThreshold ?? pricing.outputCostPerToken
            : pricing.outputCostPerToken
        return Double(input) * inputRate
            + Double(cacheRead) * cacheReadRate
            + Double(output) * outputRate
    }
}
