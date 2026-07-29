import CodexBarCore
import Foundation

/// Billing-source attribution for the "By subscription" view.
///
/// The dashboard's default grouping attributes spend to the *tool* that consumed it. A tool can
/// also act as a harness for another vendor's API, so the subscription view uses routing evidence
/// retained by the source record (`billingProviderID`) to show who actually billed the request.
///
/// `SpendBillingAttribution` re-attributes each source's daily usage to the vendor that bills it:
///
/// Model names are presentation metadata, not billing proof: Cursor can bundle a model with the
/// same family name that a user can also add through an external endpoint. Records without routing
/// evidence therefore stay with their source tool instead of being silently guessed. This rule is
/// generic across tools and model vendors; MiniMax and Claude Code are regression fixtures, not
/// special product boundaries.
enum SpendBillingAttribution {
    /// Splits every input into one attributed input per billing vendor. Vendors are keyed by
    /// `UsageProvider`, so downstream grouping/summing is unchanged — only the provider each entry
    /// is attributed to differs. Sources that keep all their usage (Cursor, Antigravity, …) come
    /// back as a single, unchanged input.
    static func attribute(
        _ inputs: [SpendDashboardModel.ProviderInput]) -> [SpendDashboardModel.ProviderInput]
    {
        // Every scanner gets the same attribution behavior. Native/bundled usage simply carries
        // no different `billingProviderID` and is preserved byte-for-byte; any harness can opt
        // into external billing by retaining the route evidence on its model breakdown.
        let fragments = inputs.flatMap(self.splitByVendor)

        // This is a provider/subscription ranking, not a tool ranking. Collapse every fragment
        // billed by the same vendor into one row and always use the vendor brand as its title.
        // Scanner labels such as "Kimi Code CLI" and "MiniMax Code" belong only in "By tool".
        let fingerprintsByProvider = Dictionary(grouping: fragments, by: \.input.provider)
            .mapValues { fragments in
                Set<String>(fragments.compactMap {
                    guard let value = $0.input.snapshot.credentialScopeFingerprint?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !value.isEmpty
                    else { return nil }
                    return value
                })
            }
        let grouped = Dictionary(grouping: fragments) { fragment in
            Self.groupKey(
                fragment,
                uniqueCredentialFingerprint: fingerprintsByProvider[fragment.input.provider]
                    .flatMap { $0.count == 1 ? $0.first : nil })
        }
        return grouped.keys.sorted { lhs, rhs in
            if lhs.provider != rhs.provider { return lhs.provider.rawValue < rhs.provider.rawValue }
            return lhs.identity < rhs.identity
        }.map { key in
            let vendor = key.provider
            let vendorFragments = grouped[key, default: []]
            let inputs = vendorFragments.map(\.input)
            let displayName = Self.vendorDisplayName(for: vendor)
            if inputs.count == 1, let input = inputs.first {
                return SpendDashboardModel.ProviderInput(
                    id: vendorFragments[0].routed
                        ? "billing:\(vendor.rawValue):\(input.id)"
                        : input.id,
                    provider: vendor,
                    displayName: displayName,
                    modelProviderName: displayName,
                    subscriptionName: input.subscriptionName,
                    snapshot: input.snapshot)
            }
            let native = vendorFragments.first { !$0.routed }?.input
            return Self.mergedInput(
                inputs,
                id: native?.id ?? "billing:\(vendor.rawValue):\(key.identity)",
                provider: vendor,
                displayName: displayName,
                modelProviderName: displayName)
        }
    }

    // MARK: - Splitting

    private struct Fragment {
        let input: SpendDashboardModel.ProviderInput
        let routed: Bool
    }

    private struct BillingGroupKey: Hashable {
        let provider: UsageProvider
        let identity: String
    }

    private static func groupKey(
        _ fragment: Fragment,
        uniqueCredentialFingerprint: String?) -> BillingGroupKey
    {
        let input = fragment.input
        if let fingerprint = input.snapshot.credentialScopeFingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !fingerprint.isEmpty
        {
            return BillingGroupKey(provider: input.provider, identity: "credential:\(fingerprint)")
        }
        if !fragment.routed,
           input.id.contains(":local"),
           let uniqueCredentialFingerprint
        {
            return BillingGroupKey(
                provider: input.provider,
                identity: "credential:\(uniqueCredentialFingerprint)")
        }
        // Codex can publish several account-scoped histories simultaneously. Keep those rows
        // separate even when an old cache predates credential fingerprints.
        if input.provider == .codex,
           input.id.hasPrefix("codex:"),
           !input.id.contains(":local")
        {
            return BillingGroupKey(provider: input.provider, identity: "source:\(input.id)")
        }
        // Other provider rows represent the currently selected account. Their native local
        // supplement and explicitly routed fragments therefore belong to the same provider row
        // unless a credential fingerprint above proves otherwise.
        return BillingGroupKey(provider: input.provider, identity: "provider-default")
    }

    private static func splitByVendor(_ input: SpendDashboardModel.ProviderInput) -> [Fragment] {
        // Bucket each day's model breakdowns by billing vendor, then rebuild one attributed input
        // per vendor with only that vendor's usage. Days where the source has no breakdowns fall
        // back to the tool's own provider so the totals still add up.
        let explicitVendors = Set(input.snapshot.daily.flatMap { entry in
            (entry.modelBreakdowns ?? []).map {
                self.billingVendor(for: $0, defaultProvider: input.provider)
            }
        })
        if explicitVendors.isEmpty || explicitVendors == [input.provider] {
            // No third-party model is present. Preserve the scanner's original aggregate proofs,
            // coverage bounds and malformed-row semantics instead of rebuilding an equivalent-
            // looking snapshot from daily rows.
            return [Fragment(input: input, routed: false)]
        }

        var dailyByVendor: [UsageProvider: [CostUsageDailyReport.Entry]] = [:]
        for entry in input.snapshot.daily {
            let breakdowns = entry.modelBreakdowns ?? []
            if breakdowns.isEmpty {
                dailyByVendor[input.provider, default: []].append(entry)
                continue
            }
            guard self.breakdownsReconcile(with: entry, breakdowns: breakdowns) else {
                // A partial breakdown cannot be split without dropping the residual usage.
                // Preserve the original aggregate under its source until stronger evidence exists.
                dailyByVendor[input.provider, default: []].append(entry)
                continue
            }
            for breakdown in breakdowns {
                let vendor = self.billingVendor(for: breakdown, defaultProvider: input.provider)
                let dayEntry = Self.entry(from: entry, keeping: breakdown)
                dailyByVendor[vendor, default: []].append(dayEntry)
            }
        }

        // Merge same-day entries per vendor (a vendor may appear in several breakdowns of one day).
        var attributed: [Fragment] = []
        for vendor in dailyByVendor.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let entries = dailyByVendor[vendor, default: []]
            let merged = Self.mergeByDay(entries)
            guard !merged.isEmpty else { continue }
            let snapshot = Self.snapshot(
                from: input.snapshot,
                daily: merged,
                historyLabel: Self.vendorDisplayName(for: vendor))
            attributed.append(Fragment(
                input: SpendDashboardModel.ProviderInput(
                    id: input.id,
                    provider: vendor,
                    displayName: Self.vendorDisplayName(for: vendor),
                    modelProviderName: Self.vendorDisplayName(for: vendor),
                    subscriptionName: vendor == input.provider ? input.subscriptionName : nil,
                    snapshot: snapshot),
                routed: vendor != input.provider))
        }
        return attributed.isEmpty ? [Fragment(input: input, routed: false)] : attributed
    }

    private static func breakdownsReconcile(
        with entry: CostUsageDailyReport.Entry,
        breakdowns: [CostUsageDailyReport.ModelBreakdown]) -> Bool
    {
        if let totalTokens = entry.totalTokens,
           sum(breakdowns.map(\.totalTokens)) != totalTokens
        {
            return false
        }
        if let cost = entry.costUSD {
            guard cost.isFinite,
                  let breakdownCost = Self.sumCost(breakdowns.map(\.costUSD)),
                  abs(breakdownCost - cost) <= max(0.000_001, abs(cost) * 0.000_001)
            else {
                return false
            }
        }
        return true
    }

    private static func mergedInput(
        _ inputs: [SpendDashboardModel.ProviderInput],
        id: String,
        provider: UsageProvider,
        displayName: String,
        modelProviderName: String) -> SpendDashboardModel.ProviderInput
    {
        guard let first = inputs.first else {
            preconditionFailure("Cannot merge an empty billing attribution input")
        }
        // A provider can publish both a live quota snapshot and a local session-history snapshot.
        // Live quota snapshots intentionally carry `historyCoverageIsEstablished == false`; mixing
        // one into complete local history used to downgrade the whole subscription to
        // "Spend unavailable" (notably MiniMax). Once at least one source establishes historical
        // coverage, only those historical sources participate in the spend/history merge.
        let establishedHistoryInputs = inputs.filter(\.snapshot.historyCoverageIsEstablished)
        let historyInputs = establishedHistoryInputs.isEmpty ? inputs : establishedHistoryInputs
        if historyInputs.count == 1, let input = historyInputs.first {
            return SpendDashboardModel.ProviderInput(
                id: input.id,
                provider: provider,
                displayName: displayName,
                modelProviderName: modelProviderName,
                subscriptionName: inputs.compactMap(\.subscriptionName).first,
                snapshot: input.snapshot)
        }

        let daily = Self.mergeByDay(historyInputs.flatMap(\.snapshot.daily))
        // These inputs are independent histories billed by the same vendor (for example, Codex
        // routing MiniMax plus MiniMax Code's native SQLite history). The merged snapshot contains
        // the union of their daily entries, so its coverage bounds must describe that union too.
        // Using the shortest history and oldest refresh time makes valid entries from the newer or
        // longer source fall outside `sourceCoverageInterval`; the dashboard then downgrades both
        // an inactive recent window and cumulative spend to "unavailable".
        let historyDays = historyInputs.map(\.snapshot.historyDays).max() ?? first.snapshot.historyDays
        let updatedAt = historyInputs.map(\.snapshot.updatedAt).max() ?? first.snapshot.updatedAt
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: Self.sum(daily.map(\.totalTokens)),
            last30DaysCostUSD: Self.sumCost(daily.map(\.costUSD)),
            last30DaysRequests: Self.sum(daily.map(\.requestCount)),
            currencyCode: historyInputs.first?.snapshot.currencyCode ?? first.snapshot.currencyCode,
            historyDays: historyDays,
            historyCoverageIsEstablished: historyInputs.allSatisfy(\.snapshot.historyCoverageIsEstablished),
            historyLabel: displayName,
            meteredCostUSD: nil,
            costSource: historyInputs.allSatisfy { $0.snapshot.costSource == .providerReported }
                ? .providerReported
                : .estimated,
            credentialScopeFingerprint: nil,
            daily: daily,
            updatedAt: updatedAt)
        return SpendDashboardModel.ProviderInput(
            id: id,
            provider: provider,
            displayName: displayName,
            modelProviderName: modelProviderName,
            subscriptionName: inputs.compactMap(\.subscriptionName).first,
            snapshot: snapshot)
    }

    /// Rebuilds a daily entry restricted to a single model breakdown, recomputing the aggregate
    /// token/cost figures from that breakdown so per-vendor day totals stay consistent.
    private static func entry(
        from entry: CostUsageDailyReport.Entry,
        keeping breakdown: CostUsageDailyReport.ModelBreakdown) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: entry.date,
            inputTokens: breakdown.inputTokens,
            outputTokens: breakdown.outputTokens,
            cacheReadTokens: breakdown.cacheReadTokens,
            cacheCreationTokens: breakdown.cacheCreationTokens,
            totalTokens: breakdown.totalTokens,
            requestCount: breakdown.requestCount,
            costUSD: breakdown.costUSD,
            modelsUsed: [breakdown.modelName],
            modelBreakdowns: [breakdown])
    }

    private static func mergeByDay(_ entries: [CostUsageDailyReport.Entry]) -> [CostUsageDailyReport.Entry] {
        let grouped = Dictionary(grouping: entries, by: \.date)
        return grouped.keys.sorted().map { day in
            let dayEntries = grouped[day] ?? []
            if dayEntries.count == 1, let only = dayEntries.first { return only }
            return CostUsageDailyReport.Entry(
                date: day,
                inputTokens: Self.sum(dayEntries.map(\.inputTokens)),
                outputTokens: Self.sum(dayEntries.map(\.outputTokens)),
                cacheReadTokens: Self.sum(dayEntries.map(\.cacheReadTokens)),
                cacheCreationTokens: Self.sum(dayEntries.map(\.cacheCreationTokens)),
                totalTokens: Self.sum(dayEntries.map(\.totalTokens)),
                requestCount: Self.sum(dayEntries.map(\.requestCount)),
                costUSD: Self.sumCost(dayEntries.map(\.costUSD)),
                modelsUsed: dayEntries.flatMap { $0.modelsUsed ?? [] },
                modelBreakdowns: dayEntries.flatMap { $0.modelBreakdowns ?? [] })
        }
    }

    private static func snapshot(
        from snapshot: CostUsageTokenSnapshot,
        daily: [CostUsageDailyReport.Entry],
        historyLabel: String) -> CostUsageTokenSnapshot
    {
        let totalTokens = Self.sum(daily.map(\.totalTokens))
        let totalCost = Self.sumCost(daily.map(\.costUSD))
        let totalRequests = Self.sum(daily.map(\.requestCount))
        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: totalTokens,
            last30DaysCostUSD: totalCost,
            last30DaysRequests: totalRequests,
            currencyCode: snapshot.currencyCode,
            historyDays: snapshot.historyDays,
            historyCoverageIsEstablished: snapshot.historyCoverageIsEstablished,
            historyLabel: historyLabel,
            meteredCostUSD: nil,
            costSource: snapshot.costSource,
            credentialScopeFingerprint: snapshot.credentialScopeFingerprint,
            daily: daily,
            updatedAt: snapshot.updatedAt)
    }

    // MARK: - Vendor mapping

    /// Compatibility helper for callers that only have a model label. A label is
    /// not routing evidence, so it deliberately keeps the source provider.
    static func billingVendor(forModel model: String, defaultProvider: UsageProvider) -> UsageProvider {
        _ = model
        return defaultProvider
    }

    private static func billingVendor(
        for breakdown: CostUsageDailyReport.ModelBreakdown,
        defaultProvider: UsageProvider) -> UsageProvider
    {
        guard let rawProviderID = breakdown.billingProviderID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !rawProviderID.isEmpty
        else {
            return defaultProvider
        }
        if let exact = UsageProvider(rawValue: rawProviderID) {
            return exact
        }
        let aliases: [String: UsageProvider] = [
            "anthropic": .claude,
            "google": .gemini,
            "google-ai": .gemini,
            "moonshotai": .kimi,
            "moonshot": .kimi,
            "openai": .openai,
            "qwen": .qwencloud,
            "alibabacloud": .qwencloud,
            "z.ai": .zai,
        ]
        return aliases[rawProviderID] ?? defaultProvider
    }

    private static func vendorDisplayName(for provider: UsageProvider) -> String {
        ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
    }

    // MARK: - Numeric helpers

    private static func sum(_ values: [Int?]) -> Int? {
        let present = values.compactMap(\.self)
        guard !present.isEmpty else { return nil }
        var total = 0
        for value in present {
            let addition = total.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            total = addition.partialValue
        }
        return total
    }

    private static func sumCost(_ values: [Double?]) -> Double? {
        let present = values.compactMap(\.self).filter(\.isFinite)
        guard !present.isEmpty else { return nil }
        let total = present.reduce(0, +)
        return total.isFinite ? total : nil
    }
}
