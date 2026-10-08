import SwiftUI

/// Inline observations beneath the matching provider's existing account and model breakdown.
struct SpendProviderPerformanceSection: View {
    let profiles: [SpendAgentProfile]
    let hidePersonalInfo: Bool
    let onSelect: ((SpendAgentProfile.Configuration) -> Void)?
    @State private var isExpanded: Bool

    init(
        profiles: [SpendAgentProfile],
        hidePersonalInfo: Bool,
        onSelect: ((SpendAgentProfile.Configuration) -> Void)? = nil,
        initiallyExpanded: Bool = false)
    {
        self.profiles = profiles
        self.hidePersonalInfo = hidePersonalInfo
        self.onSelect = onSelect
        self._isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: self.$isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(self.profiles.enumerated()), id: \.element.id) { index, profile in
                    if index > 0 { Divider() }
                    SpendProviderPerformanceRow(
                        profile: profile,
                        hidePersonalInfo: self.hidePersonalInfo,
                        showsSource: Set(self.profiles.map(\.id.sourceID)).count > 1,
                        onSelect: self.onSelect)
                }
                Text(L("Completed timed turns only. Failures and task outcomes are not recorded."))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("Task performance") + ": " + L("Not evaluated"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Text(L("Runtime performance")).fontWeight(.medium)
                Text(L("spend_agent_profile_configuration_count", codexBarLocalizedInteger(self.profiles.count)))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .help(L("Native Codex timing is currently supported."))
        }
        .font(.caption)
        .padding(.leading, 32)
        .padding(.top, 8)
        .accessibilityIdentifier("spend-provider-performance")
    }
}

private struct SpendProviderPerformanceRow: View {
    let profile: SpendAgentProfile
    let hidePersonalInfo: Bool
    let showsSource: Bool
    let onSelect: ((SpendAgentProfile.Configuration) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    self.configuration
                    Spacer(minLength: 12)
                    self.cacheFraction
                }
                VStack(alignment: .leading, spacing: 4) {
                    self.configuration
                    self.cacheFraction
                }
            }
            if self.showsSource {
                Text(self.profile.displaySourceName(hidePersonalInfo: self.hidePersonalInfo))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(L(
                "spend_agent_profile_samples",
                codexBarLocalizedInteger(self.profile.performance.sampleCount),
                codexBarLocalizedInteger(self.profile.sessions.count)))
                .font(.caption2).foregroundStyle(.secondary)
            SpendPerformanceMetricStrip(metrics: spendSessionPerformanceMetrics(self.profile.performance))
                .help(L("spend_turn_performance_help"))
            if self.profile.historyScanIsPartial {
                Label(L("Partial history"), systemImage: "exclamationmark.circle")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                DisclosureGroup(L("Performance details")) {
                    self.evidence
                }
                .font(.caption)
                Spacer(minLength: 0)
                Button(L("View sessions")) { self.onSelect?(self.profile.id) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(self.profile.sessions.isEmpty || self.onSelect == nil)
            }
        }
        .padding(.vertical, 6)
    }

    private var configuration: some View {
        HStack(spacing: 6) {
            Text(self.profile.modelName).font(.subheadline.weight(.medium))
                .lineLimit(1).truncationMode(.middle).help(self.profile.modelName)
            Text(self.profile.effortName).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var cacheFraction: some View {
        HStack(spacing: 6) {
            Text(L("spend_performance_cached_input")).foregroundStyle(.secondary)
            Text(self.profile.performance.details.cachedInputFraction.map {
                L("spend_performance_percent", Self.number($0 * 100))
            } ?? "—")
                .fontWeight(.medium)
        }
        .font(.caption).monospacedDigit().fixedSize()
        .help(L("spend_performance_cache_help"))
    }

    private var evidence: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L(
                "spend_agent_profile_cache_coverage",
                codexBarLocalizedInteger(self.profile.cacheSampleCount),
                codexBarLocalizedInteger(self.profile.performance.sampleCount)))
            Text(L(
                "First-token samples: %@ / %@",
                codexBarLocalizedInteger(self.profile.performance.firstTokenSampleCount),
                codexBarLocalizedInteger(self.profile.performance.sampleCount)))
            Text(L("Cache reuse score") + ": " +
                (self.profile.cacheScore.map {
                    Self.number($0) + "/" + codexBarLocalizedInteger(Int(SpendAgentProfile.maximumCacheScore))
                } ?? "—"))
                .help(L("Score = cached input share × 25. Experimental; not a task quality score."))
            if self.profile.cacheScore == nil,
               self.profile.cacheSampleCount < SpendAgentProfile.minimumCacheSamples
            {
                Text(L("Cache score needs five measured turns."))
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.top, 6)
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.locale(codexBarLocalizedLocale()).precision(.fractionLength(1)))
    }
}
