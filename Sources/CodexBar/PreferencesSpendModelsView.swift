import AppKit
import Charts
import CodexBarCore
import SwiftUI

enum SpendModelMetric: String, CaseIterable, Identifiable {
    case tokens
    case estimatedSpend

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .tokens: L("Tokens")
        case .estimatedSpend: L("Estimated spend")
        }
    }
}

enum SpendModelsViewMode: String, CaseIterable, Identifiable {
    case models
    case clients

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .models: L("By model")
        case .clients: L("By tool")
        }
    }
}

enum SpendModelsEnglishFormatter {
    static func dayText(_ day: Date) -> String {
        day.formatted(.dateTime.month(.abbreviated).day().locale(self.locale))
    }

    private static let locale = Locale(identifier: "en_US_POSIX")
}

func spendModelsRowDetailText(_ row: SpendModelsPresentation.Row) -> String {
    guard let value = row.value else { return "—" }
    let providers = row.source.providerNames.joined(separator: " · ")
    let metric: String = if row.source.inputTokens != nil,
                            row.source.outputTokens != nil,
                            let inputTokens = row.source.inputTokens,
                            let outputTokens = row.source.outputTokens
    {
        L(
            "%@ in · %@ out",
            UsageFormatter.tokenCountString(inputTokens),
            UsageFormatter.tokenCountString(outputTokens))
    } else {
        UsageFormatter.tokenCountString(Int(value.rounded()))
    }
    return providers.isEmpty ? metric : "\(metric) · \(providers)"
}

enum SpendModelsRanking {
    static let collapsedRowLimit = 20

    static func showsDisclosure(rowCount: Int) -> Bool {
        rowCount > self.collapsedRowLimit
    }

    static func visibleRows(
        _ rows: [SpendModelsPresentation.Row],
        showsAll: Bool) -> [SpendModelsPresentation.Row]
    {
        guard !showsAll, self.showsDisclosure(rowCount: rows.count) else { return rows }
        return Array(rows.prefix(self.collapsedRowLimit))
    }
}

struct SpendModelsPresentation: Equatable {
    struct Row: Identifiable, Equatable {
        let source: SpendDashboardModel.ModelAnalysisRow
        let rank: Int
        let value: Double?
        let share: Double?

        var id: String {
            self.source.id
        }
    }

    struct Series: Identifiable, Equatable {
        let id: String
        let name: String
        let value: Double
    }

    struct Point: Identifiable, Equatable {
        let day: Date
        let seriesID: String
        let seriesName: String
        let value: Double
        let stackStart: Double
        let stackEnd: Double

        var id: String {
            "\(self.seriesID):\(Int(self.day.timeIntervalSince1970))"
        }
    }

    let metric: SpendModelMetric
    let rows: [Row]
    let series: [Series]
    let points: [Point]
    let coverage: SpendDashboardModel.ModelMetricCoverage
    let metricTotal: Double?

    init(
        analysis: SpendDashboardModel.ModelAnalysis,
        metric: SpendModelMetric)
    {
        self.metric = metric
        self.coverage = switch metric {
        case .tokens: analysis.tokenCoverage
        case .estimatedSpend: analysis.costCoverage
        }

        let sortedSources = analysis.rows.sorted { lhs, rhs in
            Self.compare(lhs, rhs, metric: metric)
        }
        let metricValues = sortedSources.compactMap { Self.value($0, metric: metric) }
        let metricTotal = Self.sum(metricValues)
        self.metricTotal = metricTotal
        self.rows = sortedSources.enumerated().map { offset, source in
            let value = Self.value(source, metric: metric)
            return Row(
                source: source,
                rank: offset + 1,
                value: value,
                share: value.flatMap { value in
                    guard let total = metricTotal, total > 0 else { return nil }
                    return value / total
                })
        }

        let builtSeries = self.rows.compactMap { row -> Series? in
            guard let value = row.value else { return nil }
            guard value > 0 else { return nil }
            return Series(id: row.id, name: row.source.displayName, value: value)
        }
        self.series = builtSeries

        let valuesByDay = Dictionary(grouping: analysis.dailyValues, by: \.day)
        self.points = valuesByDay.keys.sorted().flatMap { day in
            let dailyValues = valuesByDay[day] ?? []
            var seriesValues: [String: Double] = [:]
            for dailyValue in dailyValues {
                guard let value = Self.value(dailyValue, metric: metric), value > 0 else { continue }
                seriesValues[dailyValue.modelID, default: 0] += value
            }
            var cursor = 0.0
            return builtSeries.compactMap { series -> Point? in
                guard let value = seriesValues[series.id], value > 0 else { return nil }
                let start = cursor
                cursor += value
                return Point(
                    day: day,
                    seriesID: series.id,
                    seriesName: series.name,
                    value: value,
                    stackStart: start,
                    stackEnd: cursor)
            }
        }
    }

    private init(
        metric: SpendModelMetric,
        rows: [Row],
        series: [Series],
        points: [Point],
        coverage: SpendDashboardModel.ModelMetricCoverage,
        metricTotal: Double?)
    {
        self.metric = metric
        self.rows = rows
        self.series = series
        self.points = points
        self.coverage = coverage
        self.metricTotal = metricTotal
    }

    // MARK: Trailing average

    static let trailingAverageWindow = 7

    /// Returns a copy whose stacked points are smoothed with a per-series trailing moving average
    /// over the visible day window (tokens.ci style). Days at the window edge average over fewer
    /// samples. Rows and series stay raw, so ranking and day details are unaffected; this is
    /// meant for the chart only.
    func applyingTrailingAverage(window: Int = Self.trailingAverageWindow) -> SpendModelsPresentation {
        guard window > 1, !self.points.isEmpty else { return self }

        let days = Array(Set(self.points.map(\.day))).sorted()
        var rawValues: [String: [Date: Double]] = [:]
        for point in self.points {
            rawValues[point.seriesID, default: [:]][point.day, default: 0] += point.value
        }

        var smoothed: [Point] = []
        for (index, day) in days.enumerated() {
            let firstSample = max(0, index - window + 1)
            let samples = days[firstSample...index]
            var cursor = 0.0
            for series in self.series {
                let total = samples.reduce(0.0) { $0 + (rawValues[series.id]?[$1] ?? 0) }
                let value = total / Double(samples.count)
                guard value > 0 else { continue }
                let start = cursor
                cursor += value
                smoothed.append(Point(
                    day: day,
                    seriesID: series.id,
                    seriesName: series.name,
                    value: value,
                    stackStart: start,
                    stackEnd: cursor))
            }
        }

        return SpendModelsPresentation(
            metric: self.metric,
            rows: self.rows,
            series: self.series,
            points: smoothed,
            coverage: self.coverage,
            metricTotal: self.metricTotal)
    }

    // MARK: Selection

    /// Returns the charted day matching `day`, or nil when it falls outside the visible range.
    func day(matching day: Date, calendar: Calendar = .current) -> Date? {
        self.points.map(\.day).first { calendar.isDate($0, inSameDayAs: day) }
    }

    private static func compare(
        _ lhs: SpendDashboardModel.ModelAnalysisRow,
        _ rhs: SpendDashboardModel.ModelAnalysisRow,
        metric: SpendModelMetric) -> Bool
    {
        switch (self.value(lhs, metric: metric), self.value(rhs, metric: metric)) {
        case let (left?, right?) where left != right: return left > right
        case (_?, nil): return true
        case (nil, _?): return false
        default:
            let otherMetric: SpendModelMetric = metric == .tokens ? .estimatedSpend : .tokens
            switch (self.value(lhs, metric: otherMetric), self.value(rhs, metric: otherMetric)) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.id < rhs.id
            }
        }
    }

    private static func value(
        _ row: SpendDashboardModel.ModelAnalysisRow,
        metric: SpendModelMetric) -> Double?
    {
        switch metric {
        case .tokens: row.totalTokens.map(Double.init)
        case .estimatedSpend: row.estimatedCost
        }
    }

    private static func value(
        _ value: SpendDashboardModel.ModelDailyValue,
        metric: SpendModelMetric) -> Double?
    {
        switch metric {
        case .tokens: value.totalTokens.map(Double.init)
        case .estimatedSpend: value.estimatedCost
        }
    }

    private static func sum(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let result = values.reduce(0, +)
        return result.isFinite ? result : nil
    }
}

struct SpendModelsAxisDates {
    static func make(
        selectedDays: Int,
        dataDays: [Date],
        domain: ClosedRange<Date>,
        calendar: Calendar = .current) -> [Date]
    {
        let normalizedDataDays = Array(Set(dataDays.map { calendar.startOfDay(for: $0) })).sorted()
        if selectedDays == 7 {
            return normalizedDataDays
        }

        let domainStart = calendar.startOfDay(for: domain.lowerBound)
        if selectedDays != 365 {
            return self.strideDates(
                from: domainStart,
                whileBefore: domain.upperBound,
                step: 7,
                calendar: calendar)
        }

        let dataEnd = normalizedDataDays.last
            ?? calendar.date(byAdding: .day, value: -1, to: domain.upperBound)
            ?? domainStart
        let daySpan = max(
            0,
            calendar.dateComponents([.day], from: domainStart, to: dataEnd).day ?? 0)
        guard daySpan > 0 else { return [domainStart] }

        // Keep the complete daily series, but limit All to roughly six readable date labels.
        let step = max(14, Int(ceil(Double(daySpan) / 5)))
        var dates = self.strideDates(
            from: domainStart,
            through: dataEnd,
            step: step,
            calendar: calendar)

        guard let last = dates.last,
              !calendar.isDate(last, inSameDayAs: dataEnd)
        else {
            return dates
        }

        let trailingGap = calendar.dateComponents([.day], from: last, to: dataEnd).day ?? step
        if trailingGap < max(7, step / 2), dates.count > 1 {
            dates[dates.count - 1] = dataEnd
        } else {
            dates.append(dataEnd)
        }
        return dates
    }

    private static func strideDates(
        from start: Date,
        whileBefore end: Date,
        step: Int,
        calendar: Calendar) -> [Date]
    {
        var dates: [Date] = []
        var cursor = start
        while cursor < end {
            dates.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: step, to: cursor) else { break }
            cursor = next
        }
        return dates
    }

    private static func strideDates(
        from start: Date,
        through end: Date,
        step: Int,
        calendar: Calendar) -> [Date]
    {
        var dates: [Date] = []
        var cursor = start
        while cursor <= end {
            dates.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: step, to: cursor) else { break }
            cursor = next
        }
        return dates
    }
}

struct SpendModelsSection: View {
    let analysis: SpendDashboardModel.ModelAnalysis
    let chartDomain: ClosedRange<Date>?
    /// Global dashboard range, passed read-only: the single top-level time-range picker drives all
    /// sections now, so this block no longer renders its own 7d/30d/All selector.
    let selectedDays: Int
    @AppStorage("spendModelsMetric") private var selectedMetric: SpendModelMetric = .tokens
    @AppStorage("spendModelsTrailingAverage") private var trailingAverage = false
    @AppStorage("spendModelsViewMode") private var viewMode: SpendModelsViewMode = .models
    @State private var selectedDay: Date?
    @State private var pinnedDay: Date?
    @State private var showsAllModels = false
    @State private var cachedPresentation: SpendModelsPresentation?
    @State private var cachedChartPresentation: SpendModelsPresentation?
    // Hover lookup caches (rebuilt alongside the presentations): a sorted unique-day list for the
    // nearest-day snap, and points grouped by start-of-day for the tooltip. Both replace an
    // O(points) scan with Calendar.isDate(inSameDayAs:) per hover tick.
    @State private var cachedSortedDays: [Date] = []
    @State private var cachedPointsByDay: [Date: [SpendModelsPresentation.Point]] = [:]

    /// Memoized presentations. Building these sorts + aggregates every model row, and the chart
    /// variant also runs the trailing-average smoothing; recomputing them on every hover tick
    /// (selectedDay changes re-evaluate body) is the hover lag. Cache and only rebuild when the
    /// inputs change, never on hover.
    private var presentation: SpendModelsPresentation {
        if let cached = self.cachedPresentation { return cached }
        return SpendModelsPresentation(analysis: self.analysis, metric: self.selectedMetric)
    }

    private var chartPresentation: SpendModelsPresentation {
        if let cached = self.cachedChartPresentation { return cached }
        let base = self.presentation
        return self.trailingAverage ? base.applyingTrailingAverage() : base
    }

    private func rebuildPresentations() {
        let base = SpendModelsPresentation(analysis: self.analysis, metric: self.selectedMetric)
        self.cachedPresentation = base
        let chart = self.trailingAverage ? base.applyingTrailingAverage() : base
        self.cachedChartPresentation = chart
        self.cachedSortedDays = Array(Set(chart.points.map(\.day))).sorted()
        self.cachedPointsByDay = Dictionary(grouping: chart.points) {
            Calendar.current.startOfDay(for: $0.day)
        }
    }

    var body: some View {
        SpendDashboardPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("Models"))
                        .font(.headline)
                    Spacer()
                    Picker(L("View"), selection: self.$viewMode) {
                        ForEach(SpendModelsViewMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                HStack(spacing: 10) {
                    if self.viewMode == .models {
                        Picker(L("Metric"), selection: self.$selectedMetric) {
                            ForEach(SpendModelMetric.allCases) { metric in
                                Text(metric.title).tag(metric)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                        Toggle(isOn: self.$trailingAverage) {
                            Text(L("7-day avg"))
                                .font(.callout)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    Spacer()
                }
                if self.viewMode == .clients {
                    SpendClientsView(analysis: self.analysis)
                } else if self.chartPresentation.points.isEmpty {
                    if self.presentation.metric == .estimatedSpend {
                        Text(L("No priced model history"))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 10)
                    } else {
                        Text(L("No model-level history"))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 10)
                    }
                } else {
                    self.chart
                    if let pinnedDay = self.pinnedDay,
                       let detail = SpendModelsDayDetailPresentation(
                           analysis: self.analysis,
                           day: pinnedDay,
                           metric: self.selectedMetric)
                    {
                        SpendModelsDayDetailView(
                            detail: detail,
                            metric: self.selectedMetric,
                            colorForModel: { self.modelColor(for: $0) })
                    }
                    self.ranking
                }
                if self.presentation.coverage == .partial {
                    Text(L("Partial model history: incomplete source-days are excluded."))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if self.showsEstimatedCostFootnote {
                    Text(L("Estimated costs are priced from local logs and may differ from provider bills."))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear {
            if self.cachedPresentation == nil { self.rebuildPresentations() }
        }
        .onChange(of: self.analysis) { _, _ in self.rebuildPresentations() }
        .onChange(of: self.selectedMetric) { _, _ in self.rebuildPresentations() }
        .onChange(of: self.trailingAverage) { _, isOn in
            // Day pinning is disabled while smoothing is on (documented tokens.ci behavior:
            // the chart shows averages, so a raw per-day panel would be misleading).
            if isOn { self.pinnedDay = nil }
            self.rebuildPresentations()
        }
        .onChange(of: self.chartPresentation.points) { _, points in
            guard let pinnedDay = self.pinnedDay else { return }
            if !Set(points.map(\.day)).contains(pinnedDay) { self.pinnedDay = nil }
        }
    }

    private var showsEstimatedCostFootnote: Bool {
        self.presentation.metric == .estimatedSpend &&
            self.presentation.rows.contains { $0.value != nil && $0.source.costIsEstimated }
    }

    private var chart: some View {
        Chart {
            ForEach(self.chartPresentation.points) { point in
                BarMark(
                    x: .value(L("Day"), point.day, unit: .day),
                    yStart: .value(self.chartPresentation.metric.title, point.stackStart),
                    yEnd: .value(self.chartPresentation.metric.title, point.stackEnd),
                    width: .ratio(0.68))
                    .foregroundStyle(by: .value(L("Models"), point.seriesName))
                    .accessibilityLabel(Text("\(point.seriesName), \(self.dayText(point.day))"))
                    .accessibilityValue(Text(self.metricText(point.value)))
            }
            if let pinnedDay = self.pinnedDay {
                RuleMark(x: .value(L("Day"), pinnedDay, unit: .day))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if let selectedDay {
                RuleMark(x: .value(L("Day"), selectedDay, unit: .day))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(
                        x: .fit(to: .chart),
                        y: .fit(to: .chart)))
                    {
                        self.tooltip(selectedDay)
                    }
            }
        }
        .chartXScale(
            domain: self.chartDomain ?? self.fallbackDomain,
            range: .plotDimension(startPadding: 10, endPadding: 30))
        .chartForegroundStyleScale(
            domain: self.presentation.series.map(\.name),
            range: self.presentation.series.indices.map { index in
                self.color(for: index)
            })
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: self.xAxisDates) { value in
                if let date = value.as(Date.self) {
                    AxisValueLabel(anchor: self.xAxisLabelAnchor(for: date)) {
                        Text(self.dayText(date))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(self.axisMetricText(amount))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(height: 220)
        .accessibilityLabel(L("Models"))
        .accessibilityValue(self.chartAccessibilityValue)
        .chartOverlay { proxy in
            GeometryReader { geo in
                SpendModelsChartMouseReader(
                    onMoved: { location in
                        self.updateSelectedDay(location: location, proxy: proxy, geo: geo)
                    },
                    onClicked: { location in
                        self.handleChartClick(location: location, proxy: proxy, geo: geo)
                    },
                    onEscape: {
                        self.pinnedDay = nil
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var ranking: some View {
        self.rankingContent
    }

    private var rankingContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(SpendModelsRanking.visibleRows(self.presentation.rows, showsAll: self.showsAllModels)) { row in
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(self.color(for: row))
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text(row.source.displayName)
                        .font(.body)
                        .lineLimit(1)
                    Spacer()
                    Text(self.rowDetail(row))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(self.shareText(row.value))
                        .font(.body.weight(.medium))
                        .monospacedDigit()
                        .frame(width: 58, alignment: .trailing)
                }
            }
            if SpendModelsRanking.showsDisclosure(rowCount: self.presentation.rows.count) {
                Button {
                    self.showsAllModels.toggle()
                } label: {
                    Text(self.showsAllModels
                        ? L("Show top 20")
                        : L("Show all %d models", self.presentation.rows.count))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func rowDetail(_ row: SpendModelsPresentation.Row) -> String {
        guard self.presentation.metric == .tokens else {
            guard let value = row.value else { return "—" }
            let providers = row.source.providerNames.joined(separator: " · ")
            var parts = [self.metricText(value)]
            if !providers.isEmpty { parts.append(providers) }
            if row.source.costIsEstimated { parts.append(L("estimated")) }
            return parts.joined(separator: " · ")
        }
        return spendModelsRowDetailText(row)
    }

    private func shareText(_ value: Double?) -> String {
        guard let value else { return "—" }
        guard let total = self.presentation.metricTotal, total > 0 else { return "—" }
        return UsageFormatter.percentString(value / total * 100)
    }

    private func tooltip(_ day: Date) -> some View {
        let points = (self.cachedPointsByDay[Calendar.current.startOfDay(for: day)] ?? [])
            .sorted { $0.value > $1.value }
        return VStack(alignment: .leading, spacing: 5) {
            Text(self.dayText(day))
                .font(.body.weight(.semibold))
            ForEach(points) { point in
                HStack(spacing: 7) {
                    Circle()
                        .fill(self.color(for: self.seriesIndex(point.seriesID)))
                        .frame(width: 8, height: 8)
                    Text(point.seriesName)
                    Spacer(minLength: 12)
                    Text(self.metricText(point.value))
                        .monospacedDigit()
                }
                .font(.body)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: .black.opacity(0.09), radius: 10, y: 3)
    }

    private var chartAccessibilityValue: String {
        let days = Set(self.chartPresentation.points.map(\.day)).count
        return L("%d days of usage data across %d models", days, self.chartPresentation.series.count)
    }

    private var fallbackDomain: ClosedRange<Date> {
        let days = self.chartPresentation.points.map(\.day)
        let start = days.min() ?? Date()
        let end = days.max() ?? start
        return start...Calendar.current.date(byAdding: .day, value: 1, to: end)!
    }

    private var xAxisDates: [Date] {
        SpendModelsAxisDates.make(
            selectedDays: self.selectedDays,
            dataDays: self.chartPresentation.points.map(\.day),
            domain: self.chartDomain ?? self.fallbackDomain)
    }

    private func xAxisLabelAnchor(for date: Date) -> UnitPoint {
        if let first = self.xAxisDates.first, Calendar.current.isDate(date, inSameDayAs: first) {
            return .topLeading
        }
        if let last = self.xAxisDates.last, Calendar.current.isDate(date, inSameDayAs: last) {
            return .topTrailing
        }
        return .top
    }

    private func metricText(_ value: Double) -> String {
        switch self.presentation.metric {
        case .tokens: UsageFormatter.tokenCountString(Int(value.rounded()))
        case .estimatedSpend: UsageFormatter.currencyString(value, currencyCode: "USD")
        }
    }

    private func axisMetricText(_ value: Double) -> String {
        switch self.presentation.metric {
        case .tokens: self.metricText(value)
        case .estimatedSpend: UsageFormatter.compactCurrencyString(value, currencyCode: "USD")
        }
    }

    private func dayText(_ day: Date) -> String {
        SpendModelsEnglishFormatter.dayText(day)
    }

    private func color(for index: Int) -> Color {
        let accentOpacities = [0.95, 0.76, 0.58, 0.42, 0.30]
        if index < accentOpacities.count {
            return Color.accentColor.opacity(accentOpacities[index])
        }
        let neutralOpacities = [0.30, 0.40, 0.50, 0.60, 0.70]
        return Color(nsColor: .secondaryLabelColor)
            .opacity(neutralOpacities[(index - accentOpacities.count) % neutralOpacities.count])
    }

    private func color(for row: SpendModelsPresentation.Row) -> Color {
        guard let index = self.presentation.series.firstIndex(where: { $0.id == row.id }) else {
            return Color(nsColor: .tertiaryLabelColor).opacity(0.55)
        }
        return self.color(for: index)
    }

    private func modelColor(for id: String) -> Color {
        guard let index = self.presentation.series.firstIndex(where: { $0.id == id }) else {
            return Color(nsColor: .tertiaryLabelColor).opacity(0.55)
        }
        return self.color(for: index)
    }

    private func seriesIndex(_ id: String) -> Int {
        self.presentation.series.firstIndex(where: { $0.id == id }) ?? 0
    }

    private func updateSelectedDay(location: CGPoint?, proxy: ChartProxy, geo: GeometryProxy) {
        guard let location, let plotAnchor = proxy.plotFrame else {
            self.selectedDay = nil
            return
        }
        let plotFrame = geo[plotAnchor]
        guard plotFrame.contains(location) else {
            self.selectedDay = nil
            return
        }
        let xInPlot = location.x - plotFrame.origin.x
        guard let date: Date = proxy.value(atX: xInPlot) else { return }
        self.selectedDay = self.nearestDay(to: date)
    }

    /// Binary search over the cached sorted day list; avoids rebuilding a Set + linear scan each
    /// hover tick.
    private func nearestDay(to date: Date) -> Date? {
        let days = self.cachedSortedDays
        guard !days.isEmpty else { return nil }
        var lo = 0, hi = days.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if days[mid] < date { lo = mid + 1 } else { hi = mid }
        }
        if lo == 0 { return days[0] }
        if lo == days.count { return days[days.count - 1] }
        let before = days[lo - 1], after = days[lo]
        return abs(before.timeIntervalSince(date)) <= abs(after.timeIntervalSince(date)) ? before : after
    }

    /// Clicking a bar day pins it (clicking the same day again clears); clicking empty space clears.
    /// Pinning is disabled while the trailing average smooths the chart.
    private func handleChartClick(location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard !self.trailingAverage else { return }
        guard let plotAnchor = proxy.plotFrame else {
            self.pinnedDay = nil
            return
        }
        let plotFrame = geo[plotAnchor]
        guard plotFrame.contains(location),
              let date: Date = proxy.value(atX: location.x - plotFrame.origin.x)
        else {
            self.pinnedDay = nil
            return
        }
        guard let day = self.nearestDay(to: date), abs(day.timeIntervalSince(date)) <= 43200 else {
            self.pinnedDay = nil
            return
        }
        self.pinnedDay = self.pinnedDay == day ? nil : day
    }
}

/// Hover/click/Escape reader for the models chart. Mirrors `MouseLocationReader` (which has no
/// click support) and adds day pinning: mouse-down reports the location, and once the view holds
/// first responder, Escape clears the pinned day.
@MainActor
private struct SpendModelsChartMouseReader: NSViewRepresentable {
    let onMoved: (CGPoint?) -> Void
    let onClicked: (CGPoint) -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMoved = self.onMoved
        view.onClicked = self.onClicked
        view.onEscape = self.onEscape
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onMoved = self.onMoved
        nsView.onClicked = self.onClicked
        nsView.onEscape = self.onEscape
    }

    final class TrackingView: NSView {
        var onMoved: ((CGPoint?) -> Void)?
        var onClicked: ((CGPoint) -> Void)?
        var onEscape: (() -> Void)?
        private var trackingArea: NSTrackingArea?

        override var isFlipped: Bool {
            true
        }

        override var acceptsFirstResponder: Bool {
            true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.window?.acceptsMouseMovedEvents = true
            self.updateTrackingAreas()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                self.removeTrackingArea(trackingArea)
            }

            let options: NSTrackingArea.Options = [
                .activeAlways,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved,
            ]
            let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
            self.addTrackingArea(area)
            self.trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            self.onMoved?(self.convert(event.locationInWindow, from: nil))
        }

        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            self.onMoved?(self.convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            self.onMoved?(nil)
        }

        override func mouseDown(with event: NSEvent) {
            self.window?.makeFirstResponder(self)
            self.onClicked?(self.convert(event.locationInWindow, from: nil))
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { // Escape
                self.onEscape?()
                self.window?.makeFirstResponder(nil)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
