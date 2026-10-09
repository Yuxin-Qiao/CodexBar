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
        self.value(dimension) + " · " + self.coverage(dimension)
    }

    func value(_ dimension: SpendHarnessRating.Dimension) -> String {
        let metrics = spendSessionPerformanceMetrics(self.performance)
        switch dimension {
        case .cache:
            return self.performance.details.cachedInputFraction.map {
                L("spend_performance_percent", Self.number($0 * 100))
            } ?? "—"
        case .response: return metrics[0].value
        case .output: return metrics[1].value
        case .duration: return metrics[2].value
        }
    }

    func coverage(_ dimension: SpendHarnessRating.Dimension) -> String {
        let count = switch dimension {
        case .cache: self.cacheSampleCount
        case .response: self.performance.firstTokenSampleCount
        case .output, .duration: self.performance.sampleCount
        }
        return L(
            "spend_harness_evidence_coverage",
            codexBarLocalizedInteger(count),
            codexBarLocalizedInteger(self.performance.sampleCount))
    }

    func definition(_ dimension: SpendHarnessRating.Dimension) -> String {
        switch dimension {
        case .cache: L("spend_performance_cache_help")
        case .response: L("Model first token may be reasoning, before visible answer text.")
        case .output: L("spend_harness_output_definition")
        case .duration: L("spend_harness_duration_definition")
        }
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var rating: SpendHarnessRating {
        SpendHarnessRating(performance: self.performance, cacheSampleCount: self.cacheSampleCount)
    }

    private var evidence: SpendHarnessRatingEvidence {
        SpendHarnessRatingEvidence(performance: self.performance, cacheSampleCount: self.cacheSampleCount)
    }

    private var style: SpendHarnessRatingStyle {
        SpendHarnessRatingStyle(colorScheme: self.colorScheme, contrast: self.contrast)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SpendHarnessRatingDetailsHeader()
            self.summary
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(self.rating.items.enumerated()), id: \.offset) { _, item in
                        self.dimensionRow(item)
                    }
                    self.method
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .scrollIndicators(.visible)
        }
        .font(.caption)
        .monospacedDigit()
        .padding(16)
        .frame(width: 440, height: 650)
        .background(.background)
        .accessibilityIdentifier("spend-harness-rating-details")
    }

    private var summary: some View {
        let color = self.style.color(for: self.rating.totalBand)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(color.opacity(0.16), lineWidth: 5)
                    if let points = self.rating.totalPoints {
                        Circle()
                            .trim(from: 0, to: Double(points) / 100)
                            .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 0) {
                            Text(codexBarLocalizedInteger(points)).font(.title.weight(.bold))
                            Text("/" + codexBarLocalizedInteger(100)).font(.caption2)
                        }
                    } else {
                        Image(systemName: "ellipsis").font(.title2.weight(.semibold))
                    }
                }
                .foregroundStyle(color)
                .frame(width: 66, height: 66)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(SpendHarnessPerformanceText(
                        performance: self.performance,
                        cacheSampleCount: self.cacheSampleCount,
                        historyScanIsPartial: self.historyScanIsPartial).scoreText)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(color)
                    Label(
                        L("spend_harness_samples", codexBarLocalizedInteger(self.performance.sampleCount)),
                        systemImage: "chart.bar.xaxis")
                        .foregroundStyle(.primary.opacity(0.72))
                }
                Spacer(minLength: 0)
            }
            SpendHarnessRatingScopeView()
        }
        .padding(12)
        .background(color.opacity(self.style.fillOpacity), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(color.opacity(self.style.borderOpacity), lineWidth: 1))
    }

    private func dimensionRow(_ item: SpendHarnessRating.Item) -> some View {
        let color = self.style.color(for: item.dimension)
        let band = item.points.map { SpendHarnessRating.Band(points: $0, maximum: item.dimension.maximumPoints) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: SpendHarnessRatingStyle.symbol(for: item.dimension))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 27, height: 27)
                    .background(color.opacity(self.style.fillOpacity), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
                Text(item.dimension.title).font(.subheadline.weight(.semibold))
                Text(self.evidence.status(item))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(self.style.color(for: band))
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(item.points.map { codexBarLocalizedInteger($0) } ?? "—")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(color)
                    Text("/" + codexBarLocalizedInteger(item.dimension.maximumPoints))
                        .foregroundStyle(.secondary)
                }
            }
            if let points = item.points {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(color.opacity(0.12))
                        Capsule().fill(color)
                            .frame(width: geometry.size.width * Double(points) / Double(item.dimension.maximumPoints))
                    }
                }
                .frame(height: 5)
                .accessibilityElement()
                .accessibilityLabel(item.dimension.title)
                .accessibilityValue(
                    codexBarLocalizedInteger(points) + "/" +
                        codexBarLocalizedInteger(item.dimension.maximumPoints))
            }
            HStack {
                Text(self.evidence.value(item.dimension))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(self.evidence.coverage(item.dimension))
                    .foregroundStyle(.primary.opacity(0.72))
            }
            Text(self.evidence.rule(item.dimension))
                .foregroundStyle(.primary.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            Text(self.evidence.definition(item.dimension))
                .foregroundStyle(.primary.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(color.opacity(self.style.fillOpacity * 0.65), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(color.opacity(self.style.borderOpacity), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var method: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(L("spend_harness_details_title"), systemImage: "info.circle")
                .font(.caption.weight(.semibold))
            Text(L("spend_harness_method", codexBarLocalizedInteger(SpendHarnessRating.minimumSamples)))
            Text(L("Native Codex timing is currently supported."))
            Text(L("Completed timed turns only. Failures and task outcomes are not recorded."))
            Text(L("spend_harness_task_help"))
            Text(L("spend_turn_performance_help"))
            Text(L("spend_harness_experimental_help"))
            if self.historyScanIsPartial { Text(L("Partial history")) }
            Text(L("spend_harness_rule_version", SpendHarnessRating.ruleVersion))
        }
        .foregroundStyle(.primary.opacity(0.72))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SpendHarnessRatingDetailsHeader: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            Text(L("spend_harness_details_title")).font(.headline)
            Spacer()
            Button(L("Close"), systemImage: "xmark") { self.dismiss() }
                .font(.caption.weight(.semibold))
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(5)
                .background(.primary.opacity(0.05), in: Circle())
                .keyboardShortcut(.cancelAction)
                .help(L("Close"))
        }
    }
}

private struct SpendHarnessRatingScopeView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("spend_harness_scope_help"))
                .fixedSize(horizontal: false, vertical: true)
            Label(L("Task performance") + " · " + L("Not evaluated"), systemImage: "checklist")
                .fontWeight(.medium)
                .help(L("spend_harness_task_help"))
        }
        .foregroundStyle(.primary.opacity(0.72))
        .accessibilityElement(children: .combine)
    }
}

struct SpendHarnessRatingUnavailableDetailsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SpendHarnessRatingDetailsHeader()
            Label(L("spend_harness_no_rating"), systemImage: "ellipsis.circle")
                .font(.title3.weight(.semibold))
            SpendHarnessRatingScopeView()
            Divider()
            ForEach(SpendHarnessRating.Dimension.allCases, id: \.self) { dimension in
                HStack {
                    Label(dimension.title, systemImage: SpendHarnessRatingStyle.symbol(for: dimension))
                    Spacer()
                    Text(L("Unavailable"))
                }
                .foregroundStyle(.secondary)
            }
            Text(L("spend_harness_no_rating_help"))
            Text(L("spend_harness_task_help"))
        }
        .font(.caption)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 440, alignment: .leading)
        .background(.background)
        .accessibilityIdentifier("spend-harness-rating-unavailable")
    }
}
