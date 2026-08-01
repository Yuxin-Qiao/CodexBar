import Foundation

/// A single normalized usage record produced by a thin per-tool parser.
///
/// This is the seam that makes the local-history framework cheap to extend, modeled on
/// tokscale's `UnifiedMessage`: a tool adapter's only job is to turn its own files into a stream
/// of `UnifiedUsageEvent`s. Aggregation, cached-prefix normalization, pricing, and snapshot
/// construction all live in one shared engine (`UsageEventAggregator`), so a new tool never
/// re-implements that logic — and can't forget it.
///
/// An event represents one billable unit (usually one request/message) on a single local day for
/// a single model. Token fields are optional because some tools (Cursor, Trae) do not mirror
/// token usage locally; a parser for such a tool emits *degraded* events with only a model and a
/// day, and the engine surfaces them as model-only entries without fabricating numbers.
public struct UnifiedUsageEvent: Sendable, Equatable {
    /// Local day the usage occurred on, in `yyyy-MM-dd` form (see `CostUsageLocalDay`).
    public var day: String
    /// Model identifier as recorded by the tool (already normalized to the pricing key, e.g.
    /// lowercase for models.dev). `"unknown"` when the tool did not record one.
    public var model: String
    /// Billing ownership evidence reported by the source record (e.g. Z.ai, `bigmodel`). Optional
    /// because many formats do not retain routing. Never guessed from the model name.
    public var billingProviderID: String?

    /// Raw input tokens as the tool reports them. May or may not include the cached prefix —
    /// see `totalTokens` for how the engine disambiguates.
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// Total tokens as the tool reports them, used to detect whether `inputTokens` already
    /// includes the cached prefix (input + output == total) or excludes it.
    public var totalTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheCreationTokens: Int?
    /// Reasoning ("thinking") tokens. Always a sub-bucket of `outputTokens`, never added on top.
    public var reasoningTokens: Int?

    /// Cost already reported by the provider for this unit, when the source retains it. Most
    /// local formats do not, so pricing normally happens in the engine against models.dev.
    public var providerCostUSD: Double?

    /// Ordered models.dev provider IDs to price this event against, from structured source
    /// evidence (never inferred from the model name). Empty means "do not price" (e.g. degraded
    /// sources or tools whose plan is flat and reported elsewhere).
    public var pricingProviderIDs: [String]

    public init(
        day: String,
        model: String,
        billingProviderID: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        providerCostUSD: Double? = nil,
        pricingProviderIDs: [String] = [])
    {
        self.day = day
        self.model = model
        self.billingProviderID = billingProviderID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.reasoningTokens = reasoningTokens
        self.providerCostUSD = providerCostUSD
        self.pricingProviderIDs = pricingProviderIDs
    }

    /// Whether this event carries any billable token information. Degraded (model-only) events
    /// return false and are surfaced without token totals.
    public var hasTokenUsage: Bool {
        (self.inputTokens ?? 0) > 0
            || (self.outputTokens ?? 0) > 0
            || (self.cacheReadTokens ?? 0) > 0
            || (self.totalTokens ?? 0) > 0
    }
}
