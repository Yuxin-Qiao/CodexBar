import CodexBarCore
import Foundation

/// Billing-source attribution for the "By subscription" view.
///
/// The dashboard's default grouping attributes spend to the *tool* that consumed it (Codex,
/// Claude Code, Cursor…). But a tool can act as a harness for another vendor's API: Claude Code
/// running on `ANTHROPIC_BASE_URL=https://api.kimi.com` is really spending Kimi credit, and Codex
/// driving `MiniMax-M3` through a third-party endpoint is really spending MiniMax credit. For the
/// subscription view the user wants to see *which vendor they actually paid*, not which UI happened
/// to issue the request.
///
/// `SpendBillingAttribution` re-attributes each source's daily usage to the vendor that bills it:
///
/// - **Cursor** keeps its bundled/default models (Claude, GPT…) under Cursor, while models reached
///   through a user-added Kimi/MiniMax/DeepSeek endpoint move to that endpoint's vendor.
/// - **Antigravity / Kimi / MiniMax CLI** keep everything under their own name. Antigravity's
///   Gemini and Claude models ship with the subscription, while the local vendor CLIs call only
///   their own plans.
/// - **Codex** is split per model: OpenAI models stay with Codex; third-party models driven through
///   a user-configured endpoint (`MiniMax-M3`, `deepseek-*`, `kimi-for-coding`) move to that vendor.
/// - **Claude Code** (used here as a free harness pointed at third-party endpoints) is split per
///   model: `claude-*` stays with Claude, everything else moves to its vendor.
///
/// Attribution currently uses the model id because that is the common field all supported local
/// scanners retain. Only explicit third-party ids move; unknown/default model ids stay with the
/// harness so attribution never guesses.
enum SpendBillingAttribution {
    /// Splits every input into one attributed input per billing vendor. Vendors are keyed by
    /// `UsageProvider`, so downstream grouping/summing is unchanged — only the provider each entry
    /// is attributed to differs. Sources that keep all their usage (Cursor, Antigravity, …) come
    /// back as a single, unchanged input.
    static func attribute(
        _ inputs: [SpendDashboardModel.ProviderInput]) -> [SpendDashboardModel.ProviderInput]
    {
        let fragments = inputs.flatMap { input -> [Fragment] in
            switch self.splitPolicy(for: input.provider) {
            case .keepAll:
                return [Fragment(input: input, routed: false)]
            case .splitByModel:
                return self.splitByVendor(input)
            }
        }

        // This is a provider/subscription ranking, not a tool ranking. Collapse every fragment
        // billed by the same vendor into one row and always use the vendor brand as its title.
        // Scanner labels such as "Kimi Code CLI" and "MiniMax Code" belong only in "By tool".
        let byVendor = Dictionary(grouping: fragments, by: \.input.provider)
        return byVendor.keys.sorted(by: { $0.rawValue < $1.rawValue }).map { vendor in
            let vendorFragments = byVendor[vendor, default: []]
            let inputs = vendorFragments.map(\.input)
            let displayName = Self.vendorDisplayName(for: vendor)
            if inputs.count == 1, let input = inputs.first {
                return SpendDashboardModel.ProviderInput(
                    id: vendorFragments[0].routed ? "billing:\(vendor.rawValue)" : input.id,
                    provider: vendor,
                    displayName: displayName,
                    modelProviderName: displayName,
                    subscriptionName: input.subscriptionName,
                    snapshot: input.snapshot)
            }
            let native = vendorFragments.first { !$0.routed }?.input
            return Self.mergedInput(
                inputs,
                id: native?.id ?? "billing:\(vendor.rawValue)",
                provider: vendor,
                displayName: displayName,
                modelProviderName: displayName)
        }
    }

    // MARK: - Policy

    private enum SplitPolicy {
        /// Everything the tool consumes is billed by the tool's own vendor (resold quota or bundled
        /// models) — no split.
        case keepAll
        /// The tool can drive third-party APIs directly; attribute each model to its own vendor.
        case splitByModel
    }

    private static func splitPolicy(for provider: UsageProvider) -> SplitPolicy {
        switch provider {
        case .codex, .claude, .cursor:
            // These harnesses can be pointed at third-party endpoints. Cursor's bundled Claude/GPT
            // ids fall back to Cursor; only explicit external-vendor ids move.
            .splitByModel
        default:
            // Antigravity bundles Claude; the local vendor CLIs (Kimi, MiniMax) only ever call
            // their own models.
            .keepAll
        }
    }

    // MARK: - Splitting

    private struct Fragment {
        let input: SpendDashboardModel.ProviderInput
        let routed: Bool
    }

    private static func splitByVendor(_ input: SpendDashboardModel.ProviderInput) -> [Fragment] {
        // Bucket each day's model breakdowns by billing vendor, then rebuild one attributed input
        // per vendor with only that vendor's usage. Days where the source has no breakdowns fall
        // back to the tool's own provider so the totals still add up.
        let explicitVendors = Set(input.snapshot.daily.flatMap { entry in
            (entry.modelBreakdowns ?? []).map {
                self.billingVendor(forModel: $0.modelName, defaultProvider: input.provider)
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
            for breakdown in breakdowns {
                let vendor = self.billingVendor(forModel: breakdown.modelName, defaultProvider: input.provider)
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
                    id: vendor == input.provider
                        ? input.id
                        : "\(input.id)|vendor:\(vendor.rawValue)",
                    provider: vendor,
                    displayName: Self.vendorDisplayName(for: vendor),
                    modelProviderName: Self.vendorDisplayName(for: vendor),
                    subscriptionName: vendor == input.provider ? input.subscriptionName : nil,
                    snapshot: snapshot),
                routed: vendor != input.provider))
        }
        return attributed.isEmpty ? [Fragment(input: input, routed: false)] : attributed
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

    /// Maps a model id to the vendor that bills it. `defaultProvider` is used when the model name
    /// carries no third-party signal (e.g. an OpenAI model inside Codex, a `claude-*` model inside
    /// Claude Code) — those stay with the tool that consumed them.
    static func billingVendor(forModel model: String, defaultProvider: UsageProvider) -> UsageProvider {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, name != "<synthetic>" else { return defaultProvider }

        // Only Codex / Claude Code ever carry third-party models; for any other tool the model is
        // billed by the tool itself, so short-circuit.
        guard defaultProvider == .codex || defaultProvider == .claude || defaultProvider == .cursor
        else { return defaultProvider }

        if name.hasPrefix("minimax") { return .minimax }
        if name.hasPrefix("deepseek") { return .deepseek }
        if name.hasPrefix("kimi") || name == "k3" || name.hasPrefix("k3-") { return .kimi }
        return defaultProvider
    }

    private static func vendorDisplayName(for provider: UsageProvider) -> String {
        ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
    }

    // MARK: - Numeric helpers

    private static func sum(_ values: [Int?]) -> Int? {
        let present = values.compactMap(\.self)
        guard !present.isEmpty else { return nil }
        return present.reduce(0, +)
    }

    private static func sumCost(_ values: [Double?]) -> Double? {
        let present = values.compactMap(\.self)
        guard !present.isEmpty else { return nil }
        return present.reduce(0, +)
    }
}
