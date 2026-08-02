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

enum SpendModelsListStyle {
    static let iconSize: CGFloat = 18
    static let iconFrameSize: CGFloat = 22
    static let modelIconSize: CGFloat = 16
    static let modelIconFrameSize: CGFloat = 20
    static let clientIconSize: CGFloat = 20
    static let clientIconFrameSize: CGFloat = 24
    static let modelRowIconSize: CGFloat = 18
    static let modelRowIconFrameSize: CGFloat = 22
    static let modelIndent: CGFloat = 48
    static let sectionTitleFont = Font.headline
    static let toolTitleFont = Font.headline
    static let primaryFont = Font.body
    static let primaryEmphasizedFont = Font.body.weight(.semibold)
    static let clientTotalsFont = Font.subheadline.weight(.medium)
    static let modelNameFont = Font.body.weight(.medium)
    static let modelCostFont = Font.body.weight(.semibold)
    static let modelDetailFont = Font.caption
    static let valueFont = Font.body.weight(.medium)
    static let secondaryFont = Font.callout
    static let tertiaryFont = Font.caption
    static let controlFont = Font.subheadline.weight(.medium)
    static let tooltipTitleFont = Font.subheadline.weight(.semibold)
    static let tooltipRowFont = Font.callout
    static let compactChartHeight: CGFloat = 144
}

enum SpendModelsDateFormatter {
    static func dayText(_ day: Date) -> String {
        day.formatted(.dateTime.month(.abbreviated).day().locale(self.locale))
    }

    private static var locale: Locale {
        .autoupdatingCurrent
    }
}

private func spendModelsTokenValueText(_ value: Double) -> String {
    guard value.isFinite, value >= 0 else { return "—" }
    if value >= Double(Int.max) {
        return UsageFormatter.tokenCountString(Int.max)
    }
    return UsageFormatter.tokenCountString(Int(value.rounded()))
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
        spendModelsTokenValueText(value)
    }
    return providers.isEmpty ? metric : "\(metric) · \(providers)"
}

func spendModelsRankingValueText(
    _ row: SpendModelsPresentation.Row,
    metric: SpendModelMetric,
    currencyCode: String = "USD") -> String
{
    switch metric {
    case .tokens:
        guard let tokens = row.source.totalTokens else { return "—" }
        return UsageFormatter.tokenCountString(tokens)
    case .estimatedSpend:
        guard let cost = row.source.estimatedCost else { return "—" }
        return UsageFormatter.currencyString(cost, currencyCode: currencyCode)
    }
}

func spendModelsRankingContextText(
    _ row: SpendModelsPresentation.Row,
    metric: SpendModelMetric,
    currencyCode: String = "USD") -> String
{
    switch metric {
    case .tokens:
        guard let cost = row.source.estimatedCost else { return "" }
        return UsageFormatter.currencyString(cost, currencyCode: currencyCode)
    case .estimatedSpend:
        guard let tokens = row.source.totalTokens else { return "" }
        return L("%@ tokens", UsageFormatter.tokenCountString(tokens))
    }
}

func spendModelsChartMetricText(
    _ value: Double,
    metric: SpendModelMetric,
    currencyCode: String = "USD") -> String
{
    switch metric {
    case .tokens:
        spendModelsTokenValueText(value)
    case .estimatedSpend:
        UsageFormatter.currencyString(value, currencyCode: currencyCode)
    }
}

enum SpendModelsRanking {
    static let collapsedRowLimit = 5

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

    var dailyTotals: [Point] {
        let pointsByDay = Dictionary(grouping: self.points, by: \.day)
        return pointsByDay.keys.sorted().compactMap { day in
            let total = pointsByDay[day, default: []].reduce(0.0) { $0 + $1.value }
            guard total > 0 else { return nil }
            return Point(
                day: day,
                seriesID: "daily-total",
                seriesName: self.metric.title,
                value: total,
                stackStart: 0,
                stackEnd: total)
        }
    }

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
    func applyingTrailingAverage(
        window: Int = Self.trailingAverageWindow,
        calendar: Calendar = .current) -> SpendModelsPresentation
    {
        guard window > 1, !self.points.isEmpty else { return self }

        let observedDays = Array(Set(self.points.map(\.day))).sorted()
        guard let firstDay = observedDays.first, let lastDay = observedDays.last else { return self }
        var normalizedCalendar = Calendar(identifier: .gregorian)
        normalizedCalendar.timeZone = calendar.timeZone
        normalizedCalendar.locale = calendar.locale
        let calendar = normalizedCalendar
        var days: [Date] = []
        var cursor = calendar.startOfDay(for: firstDay)
        let end = calendar.startOfDay(for: lastDay)
        while cursor <= end {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor),
                  next > cursor
            else {
                break
            }
            cursor = next
        }
        let displayDayByNormalizedDay = Dictionary(
            self.points.map { (calendar.startOfDay(for: $0.day), $0.day) },
            uniquingKeysWith: { first, _ in first })
        var rawValues: [String: [Date: Double]] = [:]
        for point in self.points {
            let normalizedDay = calendar.startOfDay(for: point.day)
            rawValues[point.seriesID, default: [:]][normalizedDay, default: 0] += point.value
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
                    day: displayDayByNormalizedDay[day] ?? day,
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

struct SpendModelsTokenChartPresentation: Equatable {
    struct Point: Identifiable, Equatable {
        let day: Date
        let kind: SpendModelsDayDetailPresentation.BucketKind?
        let value: Double
        let stackStart: Double
        let stackEnd: Double

        var id: String {
            "\(self.kind?.rawValue ?? "total"):\(Int(self.day.timeIntervalSince1970))"
        }
    }

    let points: [Point]

    var dailyTotals: [Point] {
        let pointsByDay = Dictionary(grouping: self.points, by: \.day)
        return pointsByDay.keys.sorted().compactMap { day in
            let total = pointsByDay[day, default: []].reduce(0.0) { $0 + $1.value }
            guard total > 0 else { return nil }
            return Point(day: day, kind: nil, value: total, stackStart: 0, stackEnd: total)
        }
    }

    init(analysis: SpendDashboardModel.ModelAnalysis) {
        let byDay = Dictionary(grouping: analysis.dailyValues, by: \.day)
        self.points = byDay.keys.sorted().flatMap { day in
            let values = byDay[day, default: []]
            let buckets: [(SpendModelsDayDetailPresentation.BucketKind?, Int)]
            if values.allSatisfy({ $0.inputTokens != nil && $0.outputTokens != nil }) {
                let input = Self.saturatingSum(values.compactMap(\.inputTokens))
                let output = Self.saturatingSum(values.compactMap(\.outputTokens))
                let cacheRead = Self.saturatingSum(values.compactMap(\.cacheReadTokens))
                let cacheWrite = Self.saturatingSum(values.compactMap(\.cacheCreationTokens))
                let reasoning = Self.saturatingSum(values.compactMap(\.reasoningTokens))
                buckets = [
                    (.input, input),
                    (.cacheRead, cacheRead),
                    (.cacheWrite, cacheWrite),
                    (.output, max(0, output - reasoning)),
                    (.reasoning, reasoning),
                ]
            } else {
                buckets = [(nil, Self.saturatingSum(values.compactMap(\.totalTokens)))]
            }
            var cursor = 0.0
            return buckets.compactMap { kind, tokens -> Point? in
                guard tokens > 0 else { return nil }
                let value = Double(tokens)
                let start = cursor
                cursor += value
                return Point(day: day, kind: kind, value: value, stackStart: start, stackEnd: cursor)
            }
        }
    }

    private init(points: [Point]) {
        self.points = points
    }

    private static func saturatingSum(_ values: [Int]) -> Int {
        values.reduce(0) { total, value in
            let result = total.addingReportingOverflow(value)
            return result.overflow ? Int.max : result.partialValue
        }
    }

    func applyingTrailingAverage(window: Int = SpendModelsPresentation.trailingAverageWindow) -> Self {
        guard window > 1, !self.points.isEmpty else { return self }
        let days = Array(Set(self.points.map(\.day))).sorted()
        var kinds: [SpendModelsDayDetailPresentation.BucketKind?] =
            SpendModelsDayDetailPresentation.BucketKind.allCases.map(\.self)
        kinds.append(nil)
        var raw: [String: [Date: Double]] = [:]
        for point in self.points {
            raw[point.kind?.rawValue ?? "total", default: [:]][point.day, default: 0] += point.value
        }
        var result: [Point] = []
        for (index, day) in days.enumerated() {
            let first = max(0, index - window + 1)
            let samples = days[first...index]
            var cursor = 0.0
            for kind in kinds {
                let id = kind?.rawValue ?? "total"
                let value = samples.reduce(0.0) { $0 + (raw[id]?[$1] ?? 0) } / Double(samples.count)
                guard value > 0 else { continue }
                let start = cursor
                cursor += value
                result.append(Point(day: day, kind: kind, value: value, stackStart: start, stackEnd: cursor))
            }
        }
        return Self(points: result)
    }
}

func spendModelsActiveChartDomain(
    selectedDays: Int,
    dataDays: [Date],
    chartDomain: ClosedRange<Date>?,
    calendar: Calendar = .current) -> ClosedRange<Date>
{
    let firstDataDay = dataDays.min() ?? Date()
    let lastDataDay = dataDays.max() ?? firstDataDay
    let fallbackEnd = calendar.date(byAdding: .day, value: 1, to: lastDataDay) ?? lastDataDay
    let fallbackDomain = firstDataDay...fallbackEnd
    guard selectedDays >= 365 else { return chartDomain ?? fallbackDomain }

    // The model builder may intentionally trim a negligible legacy island from the supplied
    // cumulative domain. Keep metric-specific framing inside that focused window instead of
    // reintroducing the trimmed observations through the raw daily values.
    let focusedDays = if let chartDomain {
        dataDays.filter(chartDomain.contains)
    } else {
        dataDays
    }
    guard let first = focusedDays.min(), let last = focusedDays.max() else {
        return chartDomain ?? fallbackDomain
    }

    let observedDays = max(
        1,
        (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1)
    let padding = min(14, max(1, Int(ceil(Double(observedDays) * 0.04))))
    let paddedStart = calendar.date(byAdding: .day, value: -padding, to: first) ?? first
    let paddedLast = calendar.date(byAdding: .day, value: padding, to: last) ?? last
    let paddedEnd = calendar.date(byAdding: .day, value: 1, to: paddedLast) ?? paddedLast
    guard let chartDomain else { return paddedStart...paddedEnd }

    let start = max(chartDomain.lowerBound, paddedStart)
    let end = min(chartDomain.upperBound, paddedEnd)
    guard start <= end else { return chartDomain }
    return start...end
}

struct SpendModelsSection: View {
    let analysis: SpendDashboardModel.ModelAnalysis
    let chartDomain: ClosedRange<Date>?
    /// Global dashboard range, passed read-only: the single top-level time-range picker drives all
    /// sections now, so this block no longer renders its own 7d/30d/All selector.
    let selectedDays: Int
    let currencyCode: String
    @AppStorage("spendModelsViewMode") private var viewMode: SpendModelsViewMode = .models
    @AppStorage("spendModelsSortMetric") private var sortMetric: SpendModelMetric = .tokens
    @State private var selectedDay: Date?
    @State private var pinnedDay: Date?
    @State private var showsAllModels = false
    @State private var cachedTokenPresentation: SpendModelsPresentation?
    @State private var cachedSpendPresentation: SpendModelsPresentation?
    @State private var cachedTokenChartPresentation = SpendModelsTokenChartPresentation(analysis: .empty)
    // Hover lookup cache: a sorted unique-day list replaces an O(points) scan with
    // Calendar.isDate(inSameDayAs:) on every pointer movement.
    @State private var cachedSortedDays: [Date] = []

    /// Memoized presentation. Building this sorts and aggregates every model row; recomputing it
    /// when selectedDay changes causes hover lag, so it is rebuilt only when the analysis changes.
    private var presentation: SpendModelsPresentation {
        if let cached = self.cachedTokenPresentation { return cached }
        return SpendModelsPresentation(analysis: self.analysis, metric: .tokens)
    }

    private var rankingPresentation: SpendModelsPresentation {
        switch self.sortMetric {
        case .tokens:
            self.cachedTokenPresentation ?? SpendModelsPresentation(analysis: self.analysis, metric: .tokens)
        case .estimatedSpend:
            self.cachedSpendPresentation
                ?? SpendModelsPresentation(analysis: self.analysis, metric: .estimatedSpend)
        }
    }

    private var chartPresentation: SpendModelsPresentation {
        self.rankingPresentation
    }

    private var hasChartData: Bool {
        switch self.sortMetric {
        case .tokens:
            !self.cachedTokenChartPresentation.points.isEmpty
        case .estimatedSpend:
            !self.chartPresentation.points.isEmpty
        }
    }

    private func rebuildPresentations() {
        let base = SpendModelsPresentation(analysis: self.analysis, metric: .tokens)
        let spend = SpendModelsPresentation(
            analysis: self.analysis,
            metric: .estimatedSpend)
        self.cachedTokenPresentation = base
        self.cachedSpendPresentation = spend
        self.cachedTokenChartPresentation = SpendModelsTokenChartPresentation(analysis: self.analysis)
        if self.sortMetric == .tokens,
           self.cachedTokenChartPresentation.points.isEmpty,
           !spend.points.isEmpty
        {
            self.sortMetric = .estimatedSpend
        }
        self.syncChartInteractionDays()
    }

    var body: some View {
        SpendDashboardPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("Models"))
                        .font(SpendModelsListStyle.sectionTitleFont)
                    Spacer()
                    Picker(L("View"), selection: self.$viewMode) {
                        ForEach(SpendModelsViewMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .font(SpendModelsListStyle.controlFont)
                    .controlSize(.small)
                    .fixedSize()
                }
                if self.viewMode == .clients {
                    SpendClientsView(analysis: self.analysis, currencyCode: self.currencyCode)
                } else if !self.hasChartData {
                    Text(L("No model-level history"))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                } else {
                    self.chart
                    if let pinnedDay = self.pinnedDay,
                       let detail = SpendModelsDayDetailPresentation(
                           analysis: self.analysis,
                           day: pinnedDay,
                           metric: self.sortMetric)
                    {
                        SpendModelsDayDetailView(
                            detail: detail,
                            metric: self.sortMetric,
                            currencyCode: self.currencyCode)
                    }
                    self.ranking
                }
                if self.presentation.coverage == .partial {
                    Text(L("Partial model history: incomplete source-days are excluded."))
                        .font(SpendModelsListStyle.secondaryFont)
                        .foregroundStyle(.tertiary)
                }
                if self.showsEstimatedCostFootnote {
                    Text(L("Estimated costs are priced from local logs and may differ from provider bills."))
                        .font(SpendModelsListStyle.secondaryFont)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear {
            if self.cachedTokenPresentation == nil { self.rebuildPresentations() }
        }
        .onChange(of: self.analysis) { _, _ in
            self.showsAllModels = false
            self.rebuildPresentations()
        }
        .onChange(of: self.chartPresentation.points) { _, points in
            guard let pinnedDay = self.pinnedDay else { return }
            if !Set(points.map(\.day)).contains(pinnedDay) { self.pinnedDay = nil }
        }
    }

    private var showsEstimatedCostFootnote: Bool {
        self.presentation.rows.contains {
            $0.source.estimatedCost != nil && $0.source.costIsEstimated
        }
    }

    private var chart: some View {
        Chart {
            if let interactionDay = self.pinnedDay ?? self.selectedDay {
                RuleMark(x: .value(L("Day"), interactionDay, unit: .day))
                    .foregroundStyle(Color.accentColor.opacity(0.09))
                    .lineStyle(StrokeStyle(lineWidth: 18))
            }
            if self.sortMetric == .tokens {
                ForEach(self.cachedTokenChartPresentation.dailyTotals) { point in
                    BarMark(
                        x: .value(L("Day"), point.day, unit: .day),
                        yStart: .value(L("Tokens"), point.stackStart),
                        yEnd: .value(L("Tokens"), point.stackEnd),
                        width: .ratio(0.62))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel(Text("\(L("Tokens")), \(self.dayText(point.day))"))
                        .accessibilityValue(Text(self.metricText(point.value)))
                }
            } else {
                ForEach(self.chartPresentation.dailyTotals) { point in
                    BarMark(
                        x: .value(L("Day"), point.day, unit: .day),
                        yStart: .value(L("Estimated spend"), point.stackStart),
                        yEnd: .value(L("Estimated spend"), point.stackEnd),
                        width: .ratio(0.62))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel(Text(
                            "\(point.seriesName), \(self.dayText(point.day))"))
                        .accessibilityValue(Text(self.metricText(point.value)))
                }
            }
            if let pinnedDay = self.pinnedDay {
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
                        self.tooltip(selectedDay)
                    }
            }
        }
        .chartXScale(
            domain: self.activeDomain,
            range: .plotDimension(startPadding: 10, endPadding: 30))
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: self.xAxisDates) { value in
                if let date = value.as(Date.self) {
                    AxisValueLabel(anchor: self.xAxisLabelAnchor(for: date)) {
                        Text(self.dayText(date))
                            .font(SpendModelsListStyle.secondaryFont)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                    .foregroundStyle(Color.secondary.opacity(0.10))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(self.axisMetricText(amount))
                            .font(SpendModelsListStyle.secondaryFont)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartPlotStyle { plotArea in
            plotArea
                .background(Color.primary.opacity(0.018))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .frame(height: SpendModelsListStyle.compactChartHeight)
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
                    onDragged: { location in
                        self.handleChartDrag(location: location, proxy: proxy, geo: geo)
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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Spacer()
                Picker(L("Models"), selection: self.$sortMetric) {
                    ForEach(SpendModelMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .font(SpendModelsListStyle.controlFont)
                .controlSize(.small)
                .fixedSize()
                .onChange(of: self.sortMetric) { _, _ in
                    self.showsAllModels = false
                    self.syncChartInteractionDays()
                }
            }
            ForEach(SpendModelsRanking.visibleRows(
                self.rankingPresentation.rows,
                showsAll: self.showsAllModels))
            { row in
                HStack(spacing: 8) {
                    Text("#\(row.rank)")
                        .font(SpendModelsListStyle.secondaryFont)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .frame(width: 28, alignment: .leading)
                    SpendProviderIcon(
                        provider: row.source.modelProvider,
                        size: SpendModelsListStyle.modelIconSize)
                        .frame(
                            width: SpendModelsListStyle.modelIconFrameSize,
                            height: SpendModelsListStyle.modelIconFrameSize)
                    Text(row.source.displayName)
                        .font(SpendModelsListStyle.primaryFont)
                        .lineLimit(1)
                        .layoutPriority(1)
                    let context = spendModelsRankingContextText(
                        row,
                        metric: self.rankingPresentation.metric,
                        currencyCode: self.currencyCode)
                    if !context.isEmpty {
                        Text("· \(context)")
                            .font(SpendModelsListStyle.secondaryFont)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    Text(spendModelsRankingValueText(
                        row,
                        metric: self.rankingPresentation.metric,
                        currencyCode: self.currencyCode))
                        .font(SpendModelsListStyle.valueFont)
                    Text("· \(self.shareText(row.value))")
                        .font(SpendModelsListStyle.secondaryFont)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.vertical, 2)
            }
            if SpendModelsRanking.showsDisclosure(rowCount: self.rankingPresentation.rows.count) {
                Button {
                    self.showsAllModels.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Text(self.showsAllModels
                            ? L("Collapse")
                            : L("Show all %d models", self.rankingPresentation.rows.count))
                        Image(systemName: self.showsAllModels ? "chevron.up" : "chevron.down")
                            .font(SpendModelsListStyle.tertiaryFont.weight(.semibold))
                    }
                    .font(SpendModelsListStyle.secondaryFont.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.08), in: Capsule())
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func shareText(_ value: Double?) -> String {
        guard let value else { return "—" }
        guard let total = self.rankingPresentation.metricTotal, total > 0 else { return "—" }
        return UsageFormatter.percentString(value / total * 100)
    }

    private func tooltip(_ day: Date) -> some View {
        let detail = SpendModelsDayDetailPresentation(
            analysis: self.analysis,
            day: day,
            metric: self.sortMetric)
        return VStack(alignment: .leading, spacing: 7) {
            if let detail {
                Text(self.dayText(day))
                    .font(SpendModelsListStyle.tooltipTitleFont)
                HStack(spacing: 14) {
                    self.tooltipSummary(
                        title: L("Tokens"),
                        value: detail.totalTokens.map(UsageFormatter.tokenCountString) ?? "—")
                    self.tooltipSummary(
                        title: L("Estimated spend"),
                        value: detail.totalCost.map {
                            UsageFormatter.currencyString($0, currencyCode: self.currencyCode)
                        } ?? "—")
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

    private var chartAccessibilityValue: String {
        let days = Set(self.chartPresentation.points.map(\.day)).count
        return L("%d days of usage data across %d models", days, self.chartPresentation.series.count)
    }

    /// Token and spend histories can have different priced coverage. In the
    /// cumulative view, frame the chart from the active metric's observations
    /// so switching metrics does not reserve months of empty space belonging
    /// only to the other metric.
    private var activeDomain: ClosedRange<Date> {
        spendModelsActiveChartDomain(
            selectedDays: self.selectedDays,
            dataDays: self.activeDataDays,
            chartDomain: self.chartDomain)
    }

    private var activeDataDays: [Date] {
        switch self.sortMetric {
        case .tokens:
            self.cachedTokenChartPresentation.dailyTotals.map(\.day)
        case .estimatedSpend:
            self.chartPresentation.dailyTotals.map(\.day)
        }
    }

    private var xAxisDates: [Date] {
        SpendModelsAxisDates.make(
            selectedDays: self.selectedDays,
            dataDays: self.activeDataDays,
            domain: self.activeDomain)
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
        spendModelsChartMetricText(value, metric: self.sortMetric, currencyCode: self.currencyCode)
    }

    private func axisMetricText(_ value: Double) -> String {
        self.metricText(value)
    }

    private func syncChartInteractionDays() {
        let days = Array(Set(self.chartPresentation.points.map(\.day))).sorted()
        self.cachedSortedDays = days
        if let selectedDay = self.selectedDay, !days.contains(selectedDay) {
            self.selectedDay = nil
        }
        if let pinnedDay = self.pinnedDay, !days.contains(pinnedDay) {
            self.pinnedDay = nil
        }
    }

    private func dayText(_ day: Date) -> String {
        SpendModelsDateFormatter.dayText(day)
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
        self.selectedDay = SpendChartDayHoverResolver.resolvedDay(
            toX: location.x - plotFrame.origin.x,
            days: self.cachedSortedDays,
            currentDay: self.selectedDay,
            position: { proxy.position(forX: $0) })
    }

    /// Clicking pins the nearest visible day inside a continuous screen-space lane. Adjacent days
    /// meet at their midpoint, so thin bars never leave dead strips between them.
    private func handleChartClick(location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard let day = self.chartDay(at: location, proxy: proxy, geo: geo) else {
            self.pinnedDay = nil
            return
        }
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
            days: self.cachedSortedDays,
            position: { proxy.position(forX: $0) })
    }
}

enum SpendChartDayHitTarget {
    static let minimumOuterExtension: CGFloat = 14

    static func nearestDay(
        toX targetX: CGFloat,
        days: [Date],
        position: (Date) -> CGFloat?) -> Date?
    {
        let positioned = days.compactMap { day in
            position(day).map { (day: day, x: $0) }
        }
        .sorted { $0.x < $1.x }
        guard !positioned.isEmpty else { return nil }

        guard let nearestIndex = positioned.indices.min(by: {
            abs(positioned[$0].x - targetX) < abs(positioned[$1].x - targetX)
        }) else { return nil }
        let nearest = positioned[nearestIndex]
        let lowerBound: CGFloat
        if nearestIndex > positioned.startIndex {
            let previous = positioned[positioned.index(before: nearestIndex)]
            lowerBound = (previous.x + nearest.x) / 2
        } else if positioned.count > 1 {
            let next = positioned[positioned.index(after: nearestIndex)]
            lowerBound = nearest.x - max(self.minimumOuterExtension, (next.x - nearest.x) / 2)
        } else {
            lowerBound = nearest.x - self.minimumOuterExtension
        }

        let upperBound: CGFloat
        if nearestIndex < positioned.index(before: positioned.endIndex) {
            let next = positioned[positioned.index(after: nearestIndex)]
            upperBound = (nearest.x + next.x) / 2
        } else if positioned.count > 1 {
            let previous = positioned[positioned.index(before: nearestIndex)]
            upperBound = nearest.x + max(self.minimumOuterExtension, (nearest.x - previous.x) / 2)
        } else {
            upperBound = nearest.x + self.minimumOuterExtension
        }
        return (lowerBound...upperBound).contains(targetX) ? nearest.day : nil
    }
}

enum SpendChartDayHoverResolver {
    /// The pointer must move this far into the neighboring date lane before hover changes.
    /// This makes dense vertical bars feel magnetized without slowing deliberate large moves.
    static let hysteresisFraction: CGFloat = 0.12
    static let minimumHysteresis: CGFloat = 1.5
    static let maximumHysteresis: CGFloat = 8

    static func resolvedDay(
        toX targetX: CGFloat,
        days: [Date],
        currentDay: Date?,
        position: (Date) -> CGFloat?) -> Date?
    {
        guard let candidate = SpendChartDayHitTarget.nearestDay(
            toX: targetX,
            days: days,
            position: position)
        else {
            return nil
        }
        guard let currentDay, currentDay != candidate else { return candidate }

        let positioned = days.compactMap { day in
            position(day).map { (day: day, x: $0) }
        }
        .sorted { $0.x < $1.x }
        guard let currentIndex = positioned.firstIndex(where: { $0.day == currentDay }),
              let candidateIndex = positioned.firstIndex(where: { $0.day == candidate })
        else {
            return candidate
        }

        // A fast move across multiple columns should catch up immediately. Hysteresis only calms
        // the ambiguous boundary between neighboring vertical date lanes.
        guard abs(candidateIndex - currentIndex) == 1 else { return candidate }
        let current = positioned[currentIndex]
        let next = positioned[candidateIndex]
        let boundary = (current.x + next.x) / 2
        let gap = abs(next.x - current.x)
        let hysteresis = min(
            self.maximumHysteresis,
            max(self.minimumHysteresis, gap * self.hysteresisFraction))

        if candidateIndex > currentIndex {
            return targetX >= boundary + hysteresis ? candidate : currentDay
        }
        return targetX <= boundary - hysteresis ? candidate : currentDay
    }
}

/// Hover/click/Escape reader for the models chart. Mirrors `MouseLocationReader` (which has no
/// click support) and adds day pinning: mouse-down reports the location, and once the view holds
/// first responder, Escape clears the pinned day.
@MainActor
struct SpendModelsChartMouseReader: NSViewRepresentable {
    let onMoved: (CGPoint?) -> Void
    let onClicked: (CGPoint) -> Void
    let onDragged: (CGPoint) -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMoved = self.onMoved
        view.onClicked = self.onClicked
        view.onDragged = self.onDragged
        view.onEscape = self.onEscape
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onMoved = self.onMoved
        nsView.onClicked = self.onClicked
        nsView.onDragged = self.onDragged
        nsView.onEscape = self.onEscape
    }

    final class TrackingView: NSView {
        var onMoved: ((CGPoint?) -> Void)?
        var onClicked: ((CGPoint) -> Void)?
        var onDragged: ((CGPoint) -> Void)?
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

        override func mouseDragged(with event: NSEvent) {
            let location = self.convert(event.locationInWindow, from: nil)
            self.onMoved?(location)
            self.onDragged?(location)
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            self.addCursorRect(self.bounds, cursor: .pointingHand)
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
