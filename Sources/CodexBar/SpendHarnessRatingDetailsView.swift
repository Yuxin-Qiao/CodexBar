import CodexBarCore
import SwiftUI

struct SpendHarnessRatingEvidence {
    let performance: CostUsageTurnPerformanceSummary
    let cacheSampleCount: Int

    func status(_ item: SpendHarnessRating.Item) -> String {
        if let description = item.description { return description }
        let count = switch item.dimension {
        case .cache: self.cacheSampleCount
        case .response: self.performance.firstTokenSampleCount
        case .output, .duration: self.performance.sampleCount
        }
        return L(count == 0 || count >= SpendHarnessRating.minimumSamples
            ? "Unavailable" : "spend_harness_observing")
    }

    func observation(_ dimension: SpendHarnessRating.Dimension) -> String {
        let metrics = spendSessionPerformanceMetrics(self.performance)
        let value: String
        let count: Int
        switch dimension {
        case .cache:
            value = self.performance.details.cachedInputFraction.map {
                L("spend_performance_percent", Self.number($0 * 100))
            } ?? "—"
            count = self.cacheSampleCount
        case .response:
            value = metrics[0].value
            count = self.performance.firstTokenSampleCount
        case .output:
            value = metrics[1].value
            count = self.performance.sampleCount
        case .duration:
            value = metrics[2].value
            count = self.performance.sampleCount
        }
        return value + " · " + L(
            "spend_harness_evidence_coverage",
            codexBarLocalizedInteger(count),
            codexBarLocalizedInteger(self.performance.sampleCount))
    }

    func rule(_ dimension: SpendHarnessRating.Dimension) -> String {
        let maximum = codexBarLocalizedInteger(dimension.maximumPoints)
        return switch dimension {
        case .cache:
            L(
                "spend_harness_cache_rule",
                L("spend_performance_percent", Self.number(SpendHarnessRating.cacheTarget * 100)),
                maximum)
        case .response:
            Self.timeRule(
                fast: SpendHarnessRating.fastResponseSeconds,
                slow: SpendHarnessRating.slowResponseSeconds,
                maximum: maximum)
        case .output:
            L(
                "spend_harness_output_rule",
                L("spend_performance_rate", Self.number(SpendHarnessRating.targetOutputTokensPerSecond)),
                maximum)
        case .duration:
            Self.timeRule(
                fast: SpendHarnessRating.shortTurnSeconds,
                slow: SpendHarnessRating.longTurnSeconds,
                maximum: maximum)
        }
    }

    private static func timeRule(fast: Double, slow: Double, maximum: String) -> String {
        L(
            "spend_harness_time_rule",
            L("spend_performance_seconds", self.number(fast)),
            maximum,
            L("spend_performance_seconds", self.number(slow)))
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.locale(codexBarLocalizedLocale()).precision(.fractionLength(0...1)))
    }
}

/// The existing inline score opens this local explanation; no additional navigation or data access.
struct SpendHarnessRatingDetailsView: View {
    let performance: CostUsageTurnPerformanceSummary
    let cacheSampleCount: Int
    let historyScanIsPartial: Bool
    @Environment(\.dismiss) private var dismiss

    private var rating: SpendHarnessRating {
        SpendHarnessRating(performance: self.performance, cacheSampleCount: self.cacheSampleCount)
    }

    private var evidence: SpendHarnessRatingEvidence {
        SpendHarnessRatingEvidence(performance: self.performance, cacheSampleCount: self.cacheSampleCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("spend_harness_details_title")).font(.headline)
                Text(L("spend_harness_experimental"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("Close"), systemImage: "xmark") { self.dismiss() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help(L("Close"))
            }
            Text(SpendHarnessPerformanceText(
                performance: self.performance,
                cacheSampleCount: self.cacheSampleCount,
                historyScanIsPartial: self.historyScanIsPartial).scoreText)
                .font(.title3.weight(.semibold))
            Text(L("spend_harness_samples", codexBarLocalizedInteger(self.performance.sampleCount)))
                .foregroundStyle(.secondary)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(self.rating.items.enumerated()), id: \.offset) { _, item in
                        self.dimensionRow(item)
                    }
                    Divider()
                    Text(L("spend_harness_method", codexBarLocalizedInteger(SpendHarnessRating.minimumSamples)))
                    Text(L("Native Codex timing is currently supported."))
                    Text(L("Completed timed turns only. Failures and task outcomes are not recorded."))
                    Text(L("spend_harness_experimental_help"))
                    if self.historyScanIsPartial { Text(L("Partial history")) }
                    Text(L("spend_harness_rule_version", SpendHarnessRating.ruleVersion))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .padding(16)
        .frame(width: 440, height: 560)
        .accessibilityIdentifier("spend-harness-rating-details")
    }

    private func dimensionRow(_ item: SpendHarnessRating.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.dimension.title).fontWeight(.semibold)
                Text(self.evidence.status(item))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(item.points.map {
                    codexBarLocalizedInteger($0) + "/" + codexBarLocalizedInteger(item.dimension.maximumPoints)
                } ?? "—")
                    .fontWeight(.semibold)
            }
            if let points = item.points {
                ProgressView(value: Double(points), total: Double(item.dimension.maximumPoints))
                    .accessibilityLabel(item.dimension.title)
            }
            Text(self.evidence.observation(item.dimension))
            Text(self.evidence.rule(item.dimension))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
