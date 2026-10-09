import CodexBarCore
import SwiftUI

extension EnvironmentValues {
    @Entry var spendDashboardIsProjecting = false
}

/// The harness's observed metrics appear directly beside its name, without another navigation level.
struct SpendHarnessPerformanceText: View {
    let performance: CostUsageTurnPerformanceSummary
    let cacheSampleCount: Int
    let historyScanIsPartial: Bool
    @Environment(\.spendDashboardIsProjecting) private var isProjecting
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var showsRatingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                self.showsRatingDetails = true
            } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 7) {
                        self.scoreBadge
                        self.dimensionBadges
                        self.detailsIcon
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            self.scoreBadge
                            self.detailsIcon
                        }
                        self.dimensionBadges
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(self.isProjecting)
            .help(L("spend_harness_open_details"))
            .accessibilityLabel(self.scoreText + " · " + self.dimensionsText)
            .accessibilityHint(L("spend_harness_open_details"))
            .popover(isPresented: self.$showsRatingDetails, arrowEdge: .bottom) {
                SpendHarnessRatingDetailsView(
                    performance: self.performance,
                    cacheSampleCount: self.cacheSampleCount,
                    historyScanIsPartial: self.historyScanIsPartial)
            }
            Text(self.observationsText)
                .foregroundStyle(.primary.opacity(0.72))
        }
        .font(.caption)
        .monospacedDigit()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("spend-harness-performance")
        .onChange(of: self.performance) { _, _ in self.showsRatingDetails = false }
        .onChange(of: self.cacheSampleCount) { _, _ in self.showsRatingDetails = false }
        .onChange(of: self.historyScanIsPartial) { _, _ in self.showsRatingDetails = false }
        .onChange(of: self.isProjecting) { _, projecting in
            if projecting { self.showsRatingDetails = false }
        }
    }

    private var rating: SpendHarnessRating {
        SpendHarnessRating(performance: self.performance, cacheSampleCount: self.cacheSampleCount)
    }

    var scoreText: String {
        if let points = self.rating.totalPoints {
            return L("spend_harness_total_score", codexBarLocalizedInteger(points)) + " · " +
                L("spend_harness_experimental")
        }
        return L("spend_harness_pending_score", codexBarLocalizedInteger(self.rating.ratedDimensionCount)) + " · " +
            L("spend_harness_experimental")
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

    private var style: SpendHarnessRatingStyle {
        SpendHarnessRatingStyle(colorScheme: self.colorScheme, contrast: self.contrast)
    }

    private var scoreBadge: some View {
        SpendHarnessScoreBadge(text: self.scoreText, band: self.rating.totalBand)
    }

    private var detailsIcon: some View {
        Image(systemName: "info.circle")
            .font(.subheadline)
            .foregroundStyle(self.style.color(for: self.rating.totalBand))
            .accessibilityHidden(true)
    }

    private var dimensionBadges: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                ForEach(Array(self.rating.items.enumerated()), id: \.offset) { _, item in
                    self.dimensionBadge(item)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    ForEach(Array(self.rating.items.prefix(2).enumerated()), id: \.offset) { _, item in
                        self.dimensionBadge(item)
                    }
                }
                HStack(spacing: 5) {
                    ForEach(Array(self.rating.items.suffix(2).enumerated()), id: \.offset) { _, item in
                        self.dimensionBadge(item)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(self.rating.items.enumerated()), id: \.offset) { _, item in
                    self.dimensionBadge(item)
                }
            }
        }
    }

    private func dimensionBadge(_ item: SpendHarnessRating.Item) -> some View {
        let color = item.points == nil ? Color.secondary : self.style.color(for: item.dimension)
        let description = item.description ?? self.unratedText(item.dimension)
        let title = item.dimension == .duration && item.description != nil
            ? description : item.dimension.title + " " + description
        return Label(title, systemImage: SpendHarnessRatingStyle.symbol(for: item.dimension))
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(self.style.fillOpacity), in: RoundedRectangle(cornerRadius: 5))
            .fixedSize()
    }

    var observationsText: String {
        let metrics = spendSessionPerformanceMetrics(self.performance)
        var components = [
            L("spend_harness_response") + " " + metrics[0].value,
            metrics[2].label + " " + metrics[2].value,
            L("spend_harness_samples", codexBarLocalizedInteger(self.performance.sampleCount)),
            L("Task performance") + " " + L("Not evaluated"),
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
            metrics[1].label + " " + metrics[1].value,
            metrics[2].label + " " + metrics[2].value,
            L("spend_performance_turn_count", codexBarLocalizedInteger(self.performance.sampleCount)),
        ]
        if self.historyScanIsPartial { components.append(L("Partial history")) }
        return components.joined(separator: " · ")
    }

    var evidenceText: String {
        var lines = [
            L("spend_harness_scope_help"),
            L("spend_harness_task_help"),
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

/// Missing timing is an unknown state with the same explanation entry point as a measured score.
struct SpendHarnessNoRatingText: View {
    @Environment(\.spendDashboardIsProjecting) private var isProjecting
    @State private var showsRatingDetails = false

    var body: some View {
        Button {
            self.showsRatingDetails = true
        } label: {
            Label(L("spend_harness_no_rating"), systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(self.isProjecting)
        .help(L("spend_harness_no_rating_help"))
        .accessibilityHint(L("spend_harness_open_details"))
        .popover(isPresented: self.$showsRatingDetails, arrowEdge: .bottom) {
            SpendHarnessRatingUnavailableDetailsView()
        }
        .onChange(of: self.isProjecting) { _, projecting in
            if projecting { self.showsRatingDetails = false }
        }
    }
}
