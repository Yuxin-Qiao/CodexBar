import AppKit
import Charts
import CodexBarCore
import SwiftUI

func spendDashboardDayRangeText(_ days: Int) -> String {
    let template: String
    switch days {
    case 7: template = L("7d")
    case 30: template = L("30d")
    case 365: return L("Cumulative")
    default: return codexBarLocalizedInteger(days)
    }
    return template.replacingOccurrences(
        of: String(days),
        with: codexBarLocalizedInteger(days))
}

func spendDashboardRankText(_ rank: Int) -> String {
    "#\(codexBarLocalizedInteger(rank))"
}

func spendDashboardRefreshFailureText(_ count: Int) -> String {
    "\(L("Refresh failures")): \(codexBarLocalizedInteger(count))"
}

func spendDashboardCoverageText(covered: Int, requested: Int) -> String {
    "\(L("Coverage")): \(spendDashboardDayRangeText(covered)) · " +
        "\(L("Time range")): \(spendDashboardDayRangeText(requested))"
}

enum SpendDashboardModelHistoryPresentation: Equatable {
    case unavailable
    case empty
    case partial
    case complete
}

func spendDashboardModelHistoryPresentation(
    _ group: SpendDashboardModel.CurrencyGroup) -> SpendDashboardModelHistoryPresentation
{
    if group.models.isEmpty {
        return group.modelHistoryCompleteness == .incomplete ? .unavailable : .empty
    }
    return group.modelHistoryCompleteness == .incomplete ? .partial : .complete
}

@MainActor
struct SpendDashboardPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    @Bindable var controller: SpendDashboardController
    private static let automaticReloadInterval: TimeInterval = 5 * 60
    private var selectedModelDays: Int {
        self.controller.selectedDays
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                self.header
                self.content
                self.provenance
                self.shareAction
            }
            .padding(24)
        }
        .background(FocusResigningBackground())
        .onAppear {
            self.controller.refreshDateWindow(reloadIfOlderThan: Self.automaticReloadInterval)
            self.controller.update(configuration: self.configuration)
        }
        .onChange(of: self.configuration) { _, configuration in
            self.controller.update(configuration: configuration)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            self.controller.refreshDateWindow(reloadIfOlderThan: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            self.controller.refreshDateWindow(reloadIfOlderThan: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.controller.refreshDateWindow(reloadIfOlderThan: Self.automaticReloadInterval)
            self.controller.update(configuration: self.configuration)
        }
    }

    private var configuration: SpendDashboardConfiguration {
        SpendDashboardSource.configuration(settings: self.settings, store: self.store)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Usage & Spend"))
                    .font(.title2.weight(.semibold))
                Text(L("Local estimated cost history across supported providers."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker(L("Time range"), selection: self.daysBinding) {
                Text(spendDashboardDayRangeText(7)).tag(7)
                Text(spendDashboardDayRangeText(30)).tag(30)
                Text(spendDashboardDayRangeText(365)).tag(365)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()

            Button {
                self.controller.refresh()
            } label: {
                if self.controller.isRefreshing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        if let progress = self.controller.codexScanProgress, progress.total > 0 {
                            Text(L("Scanning history %d/%d", progress.scanned, progress.total))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } else {
                    Label(L("Refresh"), systemImage: "arrow.clockwise")
                }
            }
            .disabled(self.controller.isRefreshing || !self.settings.costUsageEnabled)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !self.settings.costUsageEnabled {
            SpendDashboardPanel {
                ContentUnavailableView {
                    Label(L("Cost tracking is off"), systemImage: "chart.bar.xaxis")
                } description: {
                    Text(L("Turn on Track costs to build local estimates."))
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            }
        } else if self.controller.model.groups.isEmpty {
            SpendDashboardPanel {
                ContentUnavailableView {
                    Label(L("No local cost history yet"), systemImage: "chart.bar.xaxis")
                } description: {
                    Text(L("Turn on cost tracking or refresh after using a supported provider."))
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            }
        } else {
            let modelHostGroupID = self.controller.model.groups.first?.id
            let subscriptionNames = self.dashboardSubscriptionNames
            ForEach(self.controller.model.groups) { group in
                SpendCurrencySection(
                    group: group,
                    requestedDays: self.controller.model.requestedDays,
                    subscriptionNames: subscriptionNames,
                    modelAnalysis: group.id == modelHostGroupID
                        ? self.controller.model.modelAnalysis(for: self.selectedModelDays)
                        : nil,
                    modelChartDomain: group.id == modelHostGroupID
                        ? self.controller.model.modelChartDomain(for: self.selectedModelDays)
                        : nil,
                    activityAnalysis: group.id == modelHostGroupID
                        ? self.controller.model.modelAnalysis(for: 365)
                        : nil)
            }
        }

        if self.settings.costUsageEnabled, !self.controller.model.tokenActivity.isEmpty {
            SpendDashboardPanel {
                SpendActivityHeatmapView(points: self.controller.model.tokenActivity)
            }
        }

        if self.controller.failedSourceCount > 0 {
            SpendRefreshFailureNotice(
                sourceNames: self.failedSourceNames,
                refresh: { self.controller.refresh() })
        }
    }

    private var failedSourceNames: [String] {
        self.controller.failedSourceIDs.map { sourceID in
            if let codexName = self.configuration.codexAccountDisplayNames[sourceID] {
                return codexName
            }
            let providerID = sourceID.split(separator: ":", maxSplits: 1).first.map(String.init) ?? sourceID
            if let provider = UsageProvider(rawValue: providerID) {
                return self.store.metadata(for: provider).displayName
            }
            return sourceID
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var provenance: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.secondary)
            Text(L("Native currencies stay separate; Codex account rows exclude Pi session history."))
                .font(SpendModelsListStyle.secondaryFont)
                .foregroundStyle(.secondary)
            Spacer()
            Toggle(L("Track costs"), isOn: self.$settings.costUsageEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var shareAction: some View {
        HStack {
            Spacer()
            Button {
                guard let payload = self.sharePayload else { return }
                ShareStatsPresenter.shared.present(payload: payload)
            } label: {
                Label(L("Share Stats…"), systemImage: "square.and.arrow.up")
            }
            .disabled(self.sharePayload == nil)
        }
    }

    private var sharePayload: ShareStatsPayload? {
        ShareStatsBuilder.make(
            model: self.controller.model,
            subscriptionNames: self.shareSubscriptionNames)
    }

    private var dashboardSubscriptionNames: [String: String] {
        var names: [String: String] = [:]
        let codexRowCount = self.controller.model.groups
            .flatMap(\.providers)
            .count { $0.provider == .codex }
        for group in self.controller.model.groups {
            for row in group.providers {
                if let subscriptionName = row.subscriptionName {
                    names[row.id] = subscriptionName
                    continue
                }
                guard !row.id.hasPrefix("billing:") else { continue }
                let snapshots: [UsageSnapshot?] = if row.provider == .codex,
                                                     row.id.hasPrefix("codex:")
                {
                    [
                        self.store.codexAccountSnapshots.first {
                            row.id == "codex:\($0.id)"
                        }?.snapshot,
                        codexRowCount == 1 ? self.store.snapshot(for: .codex) : nil,
                    ]
                } else {
                    [self.store.snapshot(for: row.provider)]
                }
                if let name = snapshots.lazy.compactMap({
                    SpendSubscriptionPlan.from(snapshot: $0, provider: row.provider)
                }).first {
                    names[row.id] = name.displayName
                }
            }
        }
        return names
    }

    private var shareSubscriptionNames: [String: ShareStatsSubscriptionName] {
        var names: [String: ShareStatsSubscriptionName] = [:]
        let codexRowCount = self.controller.model.groups
            .flatMap(\.providers)
            .count { $0.provider == .codex }
        for group in self.controller.model.groups {
            for row in group.providers {
                // Synthetic billing rows are reconstructed from routed Codex/Claude/Cursor history,
                // so the independently configured same-vendor account may belong to a different
                // user. Never attach that account's plan to a routed-only row.
                guard !row.id.hasPrefix("billing:") else { continue }
                let snapshots: [UsageSnapshot?] = if row.provider == .codex,
                                                     row.id.hasPrefix("codex:")
                {
                    [
                        self.store.codexAccountSnapshots.first {
                            row.id == "codex:\($0.id)"
                        }?.snapshot,
                        codexRowCount == 1 ? self.store.snapshot(for: .codex) : nil,
                    ]
                } else {
                    [self.store.snapshot(for: row.provider)]
                }
                if let name = ShareStatsSubscriptionName.first(from: snapshots, provider: row.provider) {
                    names[row.id] = name
                }
            }
        }
        return names
    }

    private var daysBinding: Binding<Int> {
        Binding(
            get: { self.controller.selectedDays },
            set: { self.controller.selectDays($0) })
    }
}

private struct SpendCurrencySection: View {
    let group: SpendDashboardModel.CurrencyGroup
    let requestedDays: Int
    let subscriptionNames: [String: String]
    let modelAnalysis: SpendDashboardModel.ModelAnalysis?
    let modelChartDomain: ClosedRange<Date>?
    let activityAnalysis: SpendDashboardModel.ModelAnalysis?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(self.group.currencyCode == "XXX" ? L("Unpriced usage") : self.group.currencyCode)
                    .font(SpendModelsListStyle.sectionTitleFont)
                Spacer()
                Text(self.group.totalCost.map {
                    UsageFormatter.currencyString($0, currencyCode: self.group.currencyCode)
                } ?? L("Pricing unavailable"))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }

            Text(
                "\(L("Local estimated history")) · " +
                    spendDashboardCoverageText(
                        covered: self.group.coveredDayCount,
                        requested: self.requestedDays))
                .font(SpendModelsListStyle.secondaryFont)
                .foregroundStyle(.secondary)

            SpendDashboardPanel {
                HStack(spacing: 24) {
                    SpendSummaryValue(
                        title: self.group.costCoverage == .partial
                            ? L("Known estimated spend")
                            : L("Estimated spend"),
                        value: self.group.totalCost.map {
                            UsageFormatter.currencyString($0, currencyCode: self.group.currencyCode)
                        } ?? "—")
                    SpendSummaryValue(
                        title: L("Tracked tokens"),
                        value: self.group.totalTokens.map(UsageFormatter.tokenCountString) ?? "—")
                    SpendSummaryValue(
                        title: L("Subscriptions"),
                        value: codexBarLocalizedInteger(self.group.providers.count))
                    Spacer()
                }
            }

            SpendProviderPanel(group: self.group, subscriptionNames: self.subscriptionNames)
            if let modelAnalysis {
                SpendModelsSection(
                    analysis: modelAnalysis,
                    chartDomain: self.modelChartDomain,
                    selectedDays: self.requestedDays,
                    currencyCode: self.group.currencyCode)
            }
            if let activityAnalysis {
                SpendDashboardPanel {
                    SpendActivityHeatmapView(analysis: activityAnalysis)
                }
            }
        }
    }
}

private struct SpendSummaryValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(self.title)
                .font(SpendModelsListStyle.secondaryFont)
                .foregroundStyle(.secondary)
            Text(self.value)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
        }
    }
}

private struct SpendProviderPanel: View {
    let group: SpendDashboardModel.CurrencyGroup
    let subscriptionNames: [String: String]

    var body: some View {
        SpendDashboardPanel {
            VStack(alignment: .leading, spacing: 0) {
                Text(L("By subscription"))
                    .font(SpendModelsListStyle.sectionTitleFont)
                    .padding(.bottom, 8)
                ForEach(self.group.providers) { row in
                    if row.rank > 1 {
                        Divider()
                    }
                    HStack(spacing: 10) {
                        Text(spendDashboardRankText(row.rank))
                            .font(SpendModelsListStyle.tertiaryFont.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 26, alignment: .leading)
                        SpendProviderIcon(provider: row.provider, size: SpendModelsListStyle.iconSize)
                            .frame(width: SpendModelsListStyle.iconFrameSize)
                        Text(row.displayName)
                            .font(SpendModelsListStyle.controlFont)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if let subscriptionName = row.subscriptionName
                            ?? self.subscriptionNames[row.id]
                        {
                            Text("· \(subscriptionName)")
                                .font(SpendModelsListStyle.tertiaryFont)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 12)
                        Text(row.totalCost.map {
                            UsageFormatter.currencyString($0, currencyCode: self.group.currencyCode)
                        } ?? L("Pricing unavailable"))
                            .font(SpendModelsListStyle.controlFont)
                            .foregroundStyle(row.totalCost == nil ? .secondary : .primary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 5)
                }
                if self.group.costCoverage == .partial {
                    Text(
                        L(
                            "%d of %d subscriptions have pricing",
                            self.group.pricedProviderCount,
                            self.group.providers.count))
                        .font(SpendModelsListStyle.tertiaryFont)
                        .foregroundStyle(.secondary)
                        .padding(.top, 7)
                }
            }
        }
    }
}

private struct SpendRefreshFailureNotice: View {
    let sourceNames: [String]
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(spendDashboardRefreshFailureText(self.sourceNames.count))
                    .font(SpendModelsListStyle.secondaryFont.weight(.semibold))
                if !self.sourceNames.isEmpty {
                    Text(self.sourceNames.joined(separator: " · "))
                        .font(SpendModelsListStyle.secondaryFont)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(L("Refresh"), action: self.refresh)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.orange.opacity(0.18))
        }
    }
}

struct SpendProviderIcon: View {
    let provider: UsageProvider
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let icon = ProviderBrandIcon.image(for: self.provider) {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "circle.dotted")
            }
        }
        .foregroundStyle(.primary)
        .frame(width: self.size, height: self.size)
        .accessibilityHidden(true)
    }
}

struct SpendDashboardPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        self.content
            .padding(16)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35))
            }
    }
}
