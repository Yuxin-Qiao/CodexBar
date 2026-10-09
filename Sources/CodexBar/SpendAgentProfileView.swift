import CodexBarCore
import SwiftUI

/// The harness's observed metrics appear directly beside its name, without another navigation level.
struct SpendHarnessPerformanceText: View {
    let performance: CostUsageTurnPerformanceSummary
    let cacheSampleCount: Int
    let historyScanIsPartial: Bool

    var body: some View {
        Text(self.summaryText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .help(self.evidenceText)
            .accessibilityLabel(self.summaryText + "\n" + self.evidenceText)
            .accessibilityIdentifier("spend-harness-performance")
    }

    private var summaryText: String {
        let metrics = spendSessionPerformanceMetrics(self.performance)
        let cache = self.performance.details.cachedInputFraction.map {
            L("spend_performance_percent", Self.number($0 * 100))
        } ?? "—"
        return [
            L("spend_performance_cached_input") + " " + cache,
            metrics[0].label + " " + metrics[0].value,
            metrics[1].value,
            metrics[2].label + " " + metrics[2].value,
            L("spend_performance_turn_count", codexBarLocalizedInteger(self.performance.sampleCount)),
        ].joined(separator: " · ")
    }

    private var evidenceText: String {
        var lines = [
            L("Native Codex timing is currently supported."),
            L("Completed timed turns only. Failures and task outcomes are not recorded."),
            L("spend_turn_performance_help"),
            L("spend_performance_cache_help"),
            L(
                "spend_agent_profile_cache_coverage",
                codexBarLocalizedInteger(self.cacheSampleCount),
                codexBarLocalizedInteger(self.performance.sampleCount)),
            L(
                "First-token samples: %@ / %@",
                codexBarLocalizedInteger(self.performance.firstTokenSampleCount),
                codexBarLocalizedInteger(self.performance.sampleCount)),
        ]
        if self.cacheSampleCount >= SpendAgentProfile.minimumCacheSamples,
           let fraction = self.performance.details.cachedInputFraction
        {
            lines.append(L("Cache reuse score") + ": " +
                Self.number(fraction * SpendAgentProfile.maximumCacheScore) + "/" +
                codexBarLocalizedInteger(Int(SpendAgentProfile.maximumCacheScore)))
            lines.append(L("Score = cached input share × 25. Experimental; not a task quality score."))
        }
        if self.historyScanIsPartial { lines.append(L("Partial history")) }
        return lines.joined(separator: "\n")
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.locale(codexBarLocalizedLocale()).precision(.fractionLength(1)))
    }
}
