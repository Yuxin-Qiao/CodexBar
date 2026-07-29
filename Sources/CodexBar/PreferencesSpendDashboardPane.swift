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
                    ProgressView().controlSize(.small)
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
            SpendDailyChart(group: self.group)
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

struct SpendDailyChartPresentation: Equatable {
    enum Content: Equatable {
        case chart
        case unavailable
    }

    struct Series: Equatable {
        let name: String
        let provider: UsageProvider
    }

    let content: Content
    let series: [Series]
    let dayCount: Int

    init(dailyPoints: [SpendDashboardModel.DailyPoint], aggregateTotal: Double?) {
        self.content = dailyPoints.isEmpty && aggregateTotal == nil ? .unavailable : .chart
        self.dayCount = Set(dailyPoints.map(\.day)).count

        var seenNames: Set<String> = []
        self.series = dailyPoints.compactMap { point in
            guard seenNames.insert(point.providerName).inserted else { return nil }
            return Series(name: point.providerName, provider: point.provider)
        }
    }

    var accessibilityValue: String {
        L("%d days of usage data across %d services", self.dayCount, self.series.count)
    }
}

private struct SpendDailyChart: View {
    let group: SpendDashboardModel.CurrencyGroup
    @State private var selectedDay: Date?
    @State private var pinnedDay: Date?
    @State private var cachedDays: [Date] = []
    @State private var cachedDetails: [Date: SpendDashboardModel.DailySpendDetail] = [:]

    var body: some View {
        let presentation = SpendDailyChartPresentation(
            dailyPoints: self.group.dailyPoints,
            aggregateTotal: self.group.totalCost)
        SpendDashboardPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Daily estimated spend"))
                            .font(SpendModelsListStyle.sectionTitleFont)
                        if presentation.content == .chart {
                            Text(
                                "\(L("Active")) \(codexBarLocalizedInteger(presentation.dayCount)) · " +
                                    "\(L("Total")) \(self.totalCostText)")
                                .font(SpendModelsListStyle.secondaryFont)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                if presentation.content == .unavailable {
                    ContentUnavailableView(L("Spend unavailable"), systemImage: "chart.bar.xaxis")
                        .frame(maxWidth: .infinity, minHeight: SpendModelsListStyle.compactChartHeight)
                } else {
                    Chart {
                        if let interactionDay = self.pinnedDay ?? self.selectedDay {
                            RuleMark(x: .value(L("Day"), interactionDay, unit: .day))
                                .foregroundStyle(Color.accentColor.opacity(0.09))
                                .lineStyle(StrokeStyle(lineWidth: 18))
                        }
                        ForEach(self.group.dailyPoints) { point in
                            BarMark(
                                x: .value(L("Day"), point.day, unit: .day),
                                yStart: .value(L("Estimated spend"), point.stackStart),
                                yEnd: .value(L("Estimated spend"), point.stackEnd),
                                width: .ratio(0.58))
                                .foregroundStyle(by: .value(L("Provider"), point.providerName))
                                .accessibilityLabel(Text(self.pointAccessibilityLabel(point)))
                                .accessibilityValue(Text(UsageFormatter.currencyString(
                                    point.cost,
                                    currencyCode: self.group.currencyCode)))
                        }
                        if let pinnedDay {
                            RuleMark(x: .value(L("Day"), pinnedDay, unit: .day))
                                .foregroundStyle(Color.accentColor.opacity(0.72))
                                .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                        if let selectedDay {
                            RuleMark(x: .value(L("Day"), selectedDay, unit: .day))
                                .foregroundStyle(.clear)
                                .annotation(position: .top, overflowResolution: .init(
                                    x: .fit(to: .chart),
                                    y: .fit(to: .chart)))
                                {
                                    self.dayTooltip(selectedDay)
                                }
                        }
                    }
                    .chartXScale(domain: self.activeChartDomain)
                    .chartForegroundStyleScale(
                        domain: presentation.series.map(\.name),
                        range: presentation.series.map { self.providerColor($0.provider) })
                    .chartLegend(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 6)) { value in
                            AxisGridLine()
                                .foregroundStyle(Color.secondary.opacity(0.08))
                            AxisTick()
                                .foregroundStyle(Color.secondary.opacity(0.35))
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(date.formatted(self.axisDateFormat))
                                        .font(SpendModelsListStyle.secondaryFont)
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                                .foregroundStyle(Color.secondary.opacity(0.16))
                            AxisValueLabel {
                                if let amount = value.as(Double.self) {
                                    Text(UsageFormatter.compactCurrencyString(
                                        amount,
                                        currencyCode: self.group.currencyCode))
                                        .font(SpendModelsListStyle.secondaryFont)
                                }
                            }
                        }
                    }
                    .chartPlotStyle { plotArea in
                        plotArea
                            .background(Color.primary.opacity(0.018))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .frame(height: SpendModelsListStyle.compactChartHeight)
                    .accessibilityLabel(L("Daily estimated spend"))
                    .accessibilityValue(presentation.accessibilityValue)
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            SpendModelsChartMouseReader(
                                onMoved: { location in
                                    self.updateSelectedDay(location: location, proxy: proxy, geo: geo)
                                },
                                onClicked: { location in
                                    self.handleChartClick(location: location, proxy: proxy, geo: geo)
                                },
                                onDragged: { location in
                                    self.handleChartDrag(location: location, proxy: proxy, geo: geo)
                                },
                                onEscape: {
                                    self.selectedDay = nil
                                    self.pinnedDay = nil
                                })
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 156), spacing: 12, alignment: .leading)],
                        alignment: .leading,
                        spacing: 6)
                    {
                        ForEach(presentation.series, id: \.name) { series in
                            HStack(spacing: 6) {
                                SpendProviderIcon(provider: series.provider, size: 14)
                                    .frame(width: 18, height: 18)
                                Text(series.name)
                                    .font(SpendModelsListStyle.controlFont)
                                    .lineLimit(1)
                                if let kind = self.toolKind(for: series.name) {
                                    Text(kind.displayName)
                                        .font(SpendModelsListStyle.tertiaryFont)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    if let detail = self.pinnedDetail {
                        self.dayDetail(detail)
                    }
                }
            }
        }
        .onAppear { self.rebuildHoverCache() }
        .onChange(of: self.group.dailySpendDetails) { _, _ in self.rebuildHoverCache() }
    }

    private var totalCostText: String {
        UsageFormatter.currencyString(
            self.group.dailyPoints.reduce(0) { $0 + $1.cost },
            currencyCode: self.group.currencyCode)
    }

    private var activeChartDomain: ClosedRange<Date> {
        guard let firstDay = self.group.dailyPoints.map(\.day).min(),
              let lastDay = self.group.dailyPoints.map(\.day).max()
        else { return self.group.chartDomain }
        let calendar = Calendar.current
        let paddedStart = calendar.date(byAdding: .day, value: -1, to: firstDay) ?? firstDay
        let paddedEnd = calendar.date(byAdding: .day, value: 2, to: lastDay) ?? lastDay
        let start = max(self.group.chartDomain.lowerBound, paddedStart)
        let end = min(self.group.chartDomain.upperBound, max(paddedEnd, start))
        return start...end
    }

    private var axisDateFormat: Date.FormatStyle {
        let interval = self.activeChartDomain.upperBound.timeIntervalSince(self.activeChartDomain.lowerBound)
        if interval <= 90 * 24 * 60 * 60 {
            return .dateTime.month(.abbreviated).day().locale(codexBarLocalizedLocale())
        }
        return .dateTime.year().month(.abbreviated).locale(codexBarLocalizedLocale())
    }

    private func pointAccessibilityLabel(_ point: SpendDashboardModel.DailyPoint) -> String {
        let day = point.day.formatted(
            .dateTime.month(.abbreviated).day().locale(codexBarLocalizedLocale()))
        return "\(point.providerName), \(day)"
    }

    private func providerColor(_ provider: UsageProvider) -> Color {
        let color = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
        return Color(red: color.red, green: color.green, blue: color.blue)
    }

    private func rebuildHoverCache() {
        self.cachedDays = self.group.dailySpendDetails.map(\.day).sorted()
        self.cachedDetails = Dictionary(uniqueKeysWithValues: self.group.dailySpendDetails.map { ($0.day, $0) })
    }

    private func toolKind(for name: String) -> SpendToolIdentity.Kind? {
        self.group.dailyPoints.first { $0.providerName == name }?.toolKind
    }

    private func updateSelectedDay(location: CGPoint?, proxy: ChartProxy, geo: GeometryProxy) {
        guard let location, let plotAnchor = proxy.plotFrame else {
            self.selectedDay = nil
            return
        }
        let plotFrame = geo[plotAnchor]
        guard plotFrame.contains(location),
              let date: Date = proxy.value(atX: location.x - plotFrame.origin.x)
        else {
            self.selectedDay = nil
            return
        }
        self.selectedDay = self.nearestDay(to: date)
    }

    private func handleChartClick(location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard let day = self.chartDay(at: location, proxy: proxy, geo: geo) else { return }
        self.pinnedDay = self.pinnedDay == day ? nil : day
    }

    private func handleChartDrag(location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard let day = self.chartDay(at: location, proxy: proxy, geo: geo) else { return }
        self.pinnedDay = day
    }

    private func chartDay(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> Date? {
        guard let plotAnchor = proxy.plotFrame else { return nil }
        let plotFrame = geo[plotAnchor]
        guard plotFrame.contains(location) else { return nil }
        return SpendChartDayHitTarget.nearestDay(
            toX: location.x - plotFrame.origin.x,
            days: self.cachedDays,
            position: { proxy.position(forX: $0) })
    }

    private var pinnedDetail: SpendDashboardModel.DailySpendDetail? {
        guard let pinnedDay else { return nil }
        return self.cachedDetails[Calendar.current.startOfDay(for: pinnedDay)]
            ?? self.cachedDetails[pinnedDay]
    }

    private func nearestDay(to date: Date) -> Date? {
        let days = self.cachedDays
        guard !days.isEmpty else { return nil }
        var lower = 0
        var upper = days.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if days[middle] < date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let nearest: Date
        if lower == 0 {
            nearest = days[0]
        } else if lower == days.count {
            nearest = days[days.count - 1]
        } else {
            let before = days[lower - 1]
            let after = days[lower]
            nearest = abs(before.timeIntervalSince(date)) <= abs(after.timeIntervalSince(date))
                ? before
                : after
        }
        guard abs(nearest.timeIntervalSince(date)) <= 43200 else { return nil }
        return nearest
    }

    private func dayTooltip(_ day: Date) -> some View {
        let detail = self.cachedDetails[Calendar.current.startOfDay(for: day)]
            ?? self.cachedDetails[day]
        return VStack(alignment: .leading, spacing: 6) {
            if let detail {
                Text(day.formatted(
                    .dateTime.month(.abbreviated).day().locale(codexBarLocalizedLocale())))
                    .font(SpendModelsListStyle.tooltipTitleFont)
                HStack(spacing: 14) {
                    self.tooltipSummary(
                        title: L("Tokens"),
                        value: detail.totalTokens.map(UsageFormatter.tokenCountString) ?? "—")
                    self.tooltipSummary(
                        title: L("Estimated spend"),
                        value: UsageFormatter.currencyString(
                            detail.totalCost,
                            currencyCode: self.group.currencyCode))
                }
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: .black.opacity(0.09), radius: 10, y: 3)
    }

    private func tooltipSummary(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(SpendModelsListStyle.tertiaryFont)
                .foregroundStyle(.secondary)
            Text(value)
                .font(SpendModelsListStyle.tooltipRowFont.weight(.medium))
                .monospacedDigit()
        }
    }

    private func dayDetail(_ detail: SpendDashboardModel.DailySpendDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(detail.day.formatted(
                    .dateTime.month(.abbreviated).day().locale(codexBarLocalizedLocale())))
                    .font(SpendModelsListStyle.primaryEmphasizedFont)
                Spacer()
                if let tokens = detail.totalTokens {
                    Text(UsageFormatter.tokenCountString(tokens))
                        .font(SpendModelsListStyle.primaryFont)
                        .foregroundStyle(.secondary)
                }
                Text(UsageFormatter.currencyString(detail.totalCost, currencyCode: self.group.currencyCode))
                    .font(SpendModelsListStyle.primaryEmphasizedFont)
            }
            .monospacedDigit()

            ForEach(detail.tools) { tool in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        SpendProviderIcon(provider: tool.provider, size: SpendModelsListStyle.iconSize)
                            .frame(
                                width: SpendModelsListStyle.iconFrameSize,
                                height: SpendModelsListStyle.iconFrameSize)
                        Text(tool.displayName)
                            .font(SpendModelsListStyle.toolTitleFont)
                        Text(tool.kind.displayName)
                            .font(SpendModelsListStyle.tertiaryFont.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                        Spacer()
                        Text(UsageFormatter.currencyString(tool.cost, currencyCode: self.group.currencyCode))
                            .font(SpendModelsListStyle.primaryFont)
                            .monospacedDigit()
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(tool.models.enumerated()), id: \.element.id) { index, model in
                            if index > 0 { Divider().padding(.vertical, 2) }
                            HStack(spacing: 8) {
                                SpendProviderIcon(
                                    provider: model.modelProvider,
                                    size: SpendModelsListStyle.modelIconSize)
                                    .frame(
                                        width: SpendModelsListStyle.modelIconFrameSize,
                                        height: SpendModelsListStyle.modelIconFrameSize)
                                Text(model.displayName)
                                    .font(SpendModelsListStyle.primaryFont)
                                    .lineLimit(1)
                                Spacer()
                                Text(model.cost.map {
                                    UsageFormatter.currencyString($0, currencyCode: self.group.currencyCode)
                                } ?? model.tokens.map(UsageFormatter.tokenCountString) ?? "—")
                                    .font(SpendModelsListStyle.secondaryFont)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.leading, SpendModelsListStyle.modelIndent)
                }
                .padding(10)
                .background(
                    Color.secondary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
        .padding(11)
        .background(
            Color.secondary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
