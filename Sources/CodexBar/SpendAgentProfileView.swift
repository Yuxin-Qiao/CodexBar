import CodexBarCore
import SwiftUI

/// The harness's observed metrics appear directly beside its name, without another navigation level.
struct SpendHarnessPerformanceText: View {
    let performance: CostUsageTurnPerformanceSummary
    let cacheSampleCount: Int
    let historyScanIsPartial: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(self.ratingText)
            Text(self.observationsText)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .monospacedDigit()
        .help(self.evidenceText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.scoreText + " · " + self.dimensionsText + "\n" +
            self.observationsText + "\n" + self.evidenceText)
        .accessibilityIdentifier("spend-harness-performance")
    }

    private var rating: SpendHarnessRating {
        SpendHarnessRating(performance: self.performance, cacheSampleCount: self.cacheSampleCount)
    }

    var scoreText: String {
        if let points = self.rating.totalPoints, let band = self.rating.totalBand {
            return L("spend_harness_total_score", codexBarLocalizedInteger(points)) + " · " + band.title
        }
        return L("spend_harness_pending_score", codexBarLocalizedInteger(self.rating.ratedDimensionCount))
    }

    var dimensionsText: String {
        self.rating.items.map { item in
            let description = item.description ?? self.unratedText(item.dimension)
            if item.dimension == .duration, item.description != nil { return description }
            return item.dimension.title + " " + description
        }.joined(separator: " · ")
    }

    var componentScoresText: String {
        self.rating.items.map { item in
            let value = item.points.map {
                codexBarLocalizedInteger($0) + "/" + codexBarLocalizedInteger(item.dimension.maximumPoints)
                    + " (" + (item.description ?? "") + ")"
            } ?? self.unratedText(item.dimension)
            return item.dimension.title + " " + value
        }.joined(separator: " · ")
    }

    private func unratedText(_ dimension: SpendHarnessRating.Dimension) -> String {
        let count = switch dimension {
        case .cache: self.cacheSampleCount
        case .response: self.performance.firstTokenSampleCount
        case .output, .duration: self.performance.sampleCount
        }
        return L(count == 0 || count >= SpendHarnessRating.minimumSamples
            ? "Unavailable" : "spend_harness_observing")
    }

    private var ratingText: AttributedString {
        var score = AttributedString(self.scoreText)
        score.font = .subheadline.weight(.semibold)
        score.foregroundColor = switch self.rating.totalBand {
        case .good: .green
        case .moderate: .orange
        case .poor: .red
        case nil: .primary
        }
        var dimensions = AttributedString(" · " + self.dimensionsText)
        dimensions.foregroundColor = .secondary
        return score + dimensions
    }

    var observationsText: String {
        let metrics = spendSessionPerformanceMetrics(self.performance)
        var components = [
            L("spend_harness_response") + " " + metrics[0].value,
            metrics[2].label + " " + metrics[2].value,
            L("spend_harness_samples", codexBarLocalizedInteger(self.performance.sampleCount)),
        ]
        if self.historyScanIsPartial { components.append(L("Partial history")) }
        return components.joined(separator: " · ")
    }

    var rawMetricsText: String {
        let metrics = spendSessionPerformanceMetrics(self.performance)
        let cache = self.performance.details.cachedInputFraction.map {
            L("spend_performance_percent", Self.number($0 * 100))
        } ?? "—"
        var components = [
            L("spend_performance_cached_input") + " " + cache,
            L(
                "spend_agent_profile_cache_coverage",
                codexBarLocalizedInteger(self.cacheSampleCount),
                codexBarLocalizedInteger(self.performance.sampleCount)),
            metrics[0].label + " " + metrics[0].value,
            metrics[1].value,
            metrics[2].label + " " + metrics[2].value,
            L("spend_performance_turn_count", codexBarLocalizedInteger(self.performance.sampleCount)),
        ]
        if self.historyScanIsPartial { components.append(L("Partial history")) }
        return components.joined(separator: " · ")
    }

    var evidenceText: String {
        var lines = [
            L("Native Codex timing is currently supported."),
            L("Completed timed turns only. Failures and task outcomes are not recorded."),
            L("spend_turn_performance_help"),
            L("spend_performance_cache_help"),
            L("spend_harness_score_rule"),
            self.componentScoresText,
            L("Observed turns; workload and tools affect these results."),
            self.rawMetricsText,
            L(
                "spend_agent_profile_cache_coverage",
                codexBarLocalizedInteger(self.cacheSampleCount),
                codexBarLocalizedInteger(self.performance.sampleCount)),
            L(
                "First-token samples: %@ / %@",
                codexBarLocalizedInteger(self.performance.firstTokenSampleCount),
                codexBarLocalizedInteger(self.performance.sampleCount)),
        ]
        if self.cacheSampleCount < SpendHarnessRating.minimumSamples {
            lines.append(L("Cache score needs five measured turns."))
        }
        if self.historyScanIsPartial { lines.append(L("Partial history")) }
        return lines.joined(separator: "\n")
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.locale(codexBarLocalizedLocale()).precision(.fractionLength(1)))
    }
}
