import CodexBarCore
import SwiftUI

struct SpendAgentProfilesPanel: View {
    let profiles: [SpendAgentProfile]
    let hidePersonalInfo: Bool
    let onSelect: (SpendAgentProfile.Configuration) -> Void
    @State private var showsAllProfiles = false

    private static let collapsedProfileCount = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(L("Agent usage profiles")).font(.headline)
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(L("Native Codex timing is currently supported."))
                    .accessibilityLabel(L("Native Codex timing is currently supported."))
            }
            if self.profiles.isEmpty {
                SpendDashboardPanel {
                    Text(L("No timed turns in this period."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), alignment: .top)], spacing: 12) {
                    ForEach(self.visibleProfiles) { profile in
                        SpendAgentProfileCard(
                            profile: profile,
                            hidePersonalInfo: self.hidePersonalInfo,
                            onSelect: { self.onSelect(profile.id) })
                    }
                }
                SpendPanelExpandButton(
                    rowCount: self.profiles.count,
                    collapsedRowCount: Self.collapsedProfileCount,
                    showsAllRows: self.$showsAllProfiles)
            }
            Text(L("Completed timed turns only. Failures and task outcomes are not recorded."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("spend-agent-profiles")
    }

    private var visibleProfiles: ArraySlice<SpendAgentProfile> {
        self.profiles.prefix(self.showsAllProfiles ? self.profiles.count : Self.collapsedProfileCount)
    }
}

private struct SpendAgentProfileCard: View {
    let profile: SpendAgentProfile
    let hidePersonalInfo: Bool
    let onSelect: () -> Void

    var body: some View {
        SpendDashboardPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            // Provider-specific by design: these profiles contain only native Codex timing evidence.
                            SpendProviderIcon(provider: .codex, sourceKind: .native)
                            Text(self.profile.displaySourceName(hidePersonalInfo: self.hidePersonalInfo))
                                .font(.headline)
                        }
                        Text(self.profile.modelName).fontWeight(.medium)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(self.profile.effortName).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    self.scoreRing
                }
                Text(L(
                    "spend_agent_profile_samples",
                    codexBarLocalizedInteger(self.profile.performance.sampleCount),
                    codexBarLocalizedInteger(self.profile.sessions.count)))
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                SpendPerformanceMetricStrip(metrics: spendSessionPerformanceMetrics(self.profile.performance))
                HStack {
                    Text(L("spend_performance_cached_input")).foregroundStyle(.secondary)
                    Spacer()
                    Text(self.cacheFractionText).fontWeight(.medium)
                }
                .font(.caption).monospacedDigit()
                .help(L("spend_performance_cache_help"))
                Text(L(
                    "spend_agent_profile_cache_coverage",
                    codexBarLocalizedInteger(self.profile.cacheSampleCount),
                    codexBarLocalizedInteger(self.profile.performance.sampleCount)))
                    .font(.caption2).foregroundStyle(.secondary)
                Text(L(
                    "First-token samples: %@ / %@",
                    codexBarLocalizedInteger(self.profile.performance.firstTokenSampleCount),
                    codexBarLocalizedInteger(self.profile.performance.sampleCount)))
                    .font(.caption2).foregroundStyle(.secondary)
                if self.profile.cacheScore == nil,
                   self.profile.cacheSampleCount < SpendAgentProfile.minimumCacheSamples
                {
                    Text(L("Cache score needs five measured turns."))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if self.profile.historyScanIsPartial {
                    Label(L("Partial history"), systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Text(L("Task performance")).foregroundStyle(.secondary)
                    Spacer()
                    Text(L("Not evaluated")).foregroundStyle(.secondary)
                }
                .font(.caption)
                Button(L("View sessions"), action: self.onSelect)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(self.profile.sessions.isEmpty)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var scoreRing: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.14), lineWidth: 5)
                if let score = self.profile.cacheScore {
                    Circle().trim(from: 0, to: score / SpendAgentProfile.maximumCacheScore)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 0) {
                    Text(self.profile.cacheScore.map(Self.number) ?? "—")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                    Text("/" + codexBarLocalizedInteger(Int(SpendAgentProfile.maximumCacheScore)))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 62, height: 62)
            Text(L("Cache reuse score")).font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(width: 86)
        }
        .accessibilityElement(children: .combine)
        .help(L("Score = cached input share × 25. Experimental; not a task quality score."))
    }

    private var cacheFractionText: String {
        self.profile.performance.details.cachedInputFraction.map {
            L("spend_performance_percent", Self.number($0 * 100))
        } ?? "—"
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.locale(codexBarLocalizedLocale()).precision(.fractionLength(1)))
    }
}
