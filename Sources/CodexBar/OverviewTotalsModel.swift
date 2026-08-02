import CodexBarCore
import Foundation

/// Cross-provider aggregate shown at the top of the merged Overview menu. Inputs are the
/// currently published, current-config token snapshots of enabled providers; the model only
/// sums compatible units (tokens are provider-agnostic, cost is grouped by effective currency).
struct OverviewTotalsModel: Equatable, Sendable {
    struct ProviderInput: Sendable {
        let provider: UsageProvider
        let displayName: String
        let snapshot: CostUsageTokenSnapshot
    }

    struct ProviderContribution: Equatable, Sendable, Identifiable {
        let provider: UsageProvider
        let providerName: String
        let totalTokens: Int?
        let totalCost: Double?
        let currencyCode: String
        let coveredDayCount: Int

        var id: String {
            self.provider.rawValue
        }
    }

    struct CurrencyGroup: Equatable, Sendable, Identifiable {
        let currencyCode: String
        let totalCost: Double?
        let totalTokens: Int?
        let coveredDayCount: Int
        let contributions: [ProviderContribution]

        var id: String {
            self.currencyCode
        }
    }

    let requestedDays: Int
    let providerCount: Int
    let groups: [CurrencyGroup]

    var totalTokens: Int? {
        let tokenTotals = self.groups.map(\.totalTokens)
        guard tokenTotals.allSatisfy({ $0 != nil }) else { return nil }
        return tokenTotals.reduce(into: 0) { partial, total in
            partial += total ?? 0
        }
    }

    var coveredDayCount: Int {
        self.groups.map(\.coveredDayCount).max() ?? self.requestedDays
    }

    var heightFingerprint: String {
        let groupFingerprints = self.groups.map { group in
            [
                group.currencyCode,
                group.totalCost.map { String($0) } ?? "-",
                group.totalTokens.map { String($0) } ?? "-",
                String(group.coveredDayCount),
                group.contributions.map(\.provider.rawValue).joined(separator: ","),
            ].joined(separator: "|")
        }
        return [
            "overviewTotals",
            String(self.providerCount),
            String(self.requestedDays),
            groupFingerprints.joined(separator: ";"),
        ].joined(separator: ":")
    }

    static func build(
        inputs: [ProviderInput],
        requestedDays: Int = 30,
        preferredCurrencyCode: String = "auto") -> OverviewTotalsModel?
    {
        guard inputs.count >= 2 else { return nil }
        let classified = inputs.compactMap { input -> ClassifiedInput? in
            guard let sourceCurrency = Self.currencyCode(input.snapshot.currencyCode) else { return nil }
            let converted = UsageFormatter.convertedCost(
                1,
                preferredCurrency: preferredCurrencyCode,
                providerCurrency: sourceCurrency)
            return ClassifiedInput(
                currencyCode: converted.currencyCode,
                input: input,
                costMultiplier: converted.value)
        }
        guard !classified.isEmpty else { return nil }

        let groups = Dictionary(grouping: classified, by: { $0.currencyCode })
            .map { currencyCode, inputs in
                Self.buildGroup(currencyCode: currencyCode, inputs: inputs)
            }
            .sorted { $0.currencyCode < $1.currencyCode }
        return OverviewTotalsModel(
            requestedDays: requestedDays,
            providerCount: classified.count,
            groups: groups)
    }

    private struct ClassifiedInput {
        let currencyCode: String
        let input: ProviderInput
        let costMultiplier: Double
    }

    private static func buildGroup(
        currencyCode: String,
        inputs: [ClassifiedInput]) -> CurrencyGroup
    {
        var contributions: [ProviderContribution] = []
        var totalTokens: Int?
        var tokenOverflowed = false
        var tokenIncomplete = false
        var totalCost: Double?
        var costOverflowed = false
        var maxCoveredDayCount = 0

        for classified in inputs.sorted(by: { $0.input.provider.rawValue < $1.input.provider.rawValue }) {
            let snapshot = classified.input.snapshot
            maxCoveredDayCount = max(maxCoveredDayCount, snapshot.historyDays)

            let tokens = snapshot.last30DaysTokens
            tokenIncomplete = tokenIncomplete || tokens == nil
            if !tokenOverflowed, let tokens {
                if let existingTokens = totalTokens {
                    let (partial, overflow) = existingTokens.addingReportingOverflow(tokens)
                    if overflow {
                        tokenOverflowed = true
                        totalTokens = nil
                    } else {
                        totalTokens = partial
                    }
                } else {
                    totalTokens = tokens
                }
            }

            let cost = snapshot.last30DaysCostUSD.map { $0 * classified.costMultiplier }
            if !costOverflowed, let cost, cost.isFinite {
                if let existingCost = totalCost {
                    let sum = existingCost + cost
                    if sum.isFinite {
                        totalCost = sum
                    } else {
                        costOverflowed = true
                        totalCost = nil
                    }
                } else {
                    totalCost = cost
                }
            }

            contributions.append(ProviderContribution(
                provider: classified.input.provider,
                providerName: classified.input.displayName,
                totalTokens: tokens,
                totalCost: cost,
                currencyCode: currencyCode,
                coveredDayCount: snapshot.historyDays))
        }

        return CurrencyGroup(
            currencyCode: currencyCode,
            totalCost: totalCost,
            totalTokens: tokenIncomplete || tokenOverflowed ? nil : totalTokens,
            coveredDayCount: maxCoveredDayCount,
            contributions: contributions)
    }

    private static func currencyCode(_ raw: String) -> String? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized.isEmpty || normalized == "XXX" ? nil : normalized
    }
}
