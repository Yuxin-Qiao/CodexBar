import CodexBarCore
import SwiftUI

// MARK: - Token 活动热力图（参照 Codex `/usage` 的图表算法）

enum SpendActivityViewMode: String, CaseIterable, Identifiable {
    case daily
    case weekly
    case cumulative

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .daily: L("Daily")
        case .weekly: L("Weekly")
        case .cumulative: L("Cumulative")
        }
    }
}

/// Per-day token totals keyed by start-of-day, plus the fixed 52-week window Codex uses.
struct SpendActivitySeries {
    /// 52*7 values ordered oldest-first, starting at the Sunday 51 weeks before this week's Sunday.
    let daily: [Int]
    /// Naive start-of-day for `daily[0]`.
    let start: Date
    let today: Date
    let calendar: Calendar

    static let weekCount = 52
    static let dayCount = 7

    /// Builds the fixed 52-week window ending this week (GitHub/Codex style). The first cell is the
    /// Sunday that begins the oldest week, so the last column always lands on the current week.
    static func make(
        from analysis: SpendDashboardModel.ModelAnalysis,
        calendar: Calendar = .current) -> SpendActivitySeries
    {
        var totals: [Date: Int] = [:]
        for value in analysis.dailyValues {
            let day = calendar.startOfDay(for: value.day)
            totals[day, default: 0] += max(value.totalTokens ?? 0, 0)
        }

        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today) // 1 = Sunday
        let thisWeekSunday = calendar.date(byAdding: .day, value: -(weekday - 1), to: today)!
        let start = calendar.date(byAdding: .weekOfYear, value: -(Self.weekCount - 1), to: thisWeekSunday)!

        let cellCount = Self.weekCount * Self.dayCount
        var daily = [Int](repeating: 0, count: cellCount)
        for offset in 0..<cellCount {
            guard let date = calendar.date(byAdding: .day, value: offset, to: start), date <= today else { continue }
            daily[offset] = totals[date] ?? 0
        }
        return SpendActivitySeries(daily: daily, start: start, today: today, calendar: calendar)
    }

    func date(at index: Int) -> Date? {
        self.calendar.date(byAdding: .day, value: index, to: self.start)
    }
}

enum SpendActivityLevels {
    /// Codex's 5-step daily grading: ratio against the window max (linear, not log).
    /// >3/4 max → 4, >1/2 max → 3, >1/4 max → 2, >0 → 1, 0 → 0.
    static func dailyLevels(_ values: [Int]) -> [Int] {
        let maxValue = values.max() ?? 0
        return values.map { value in
            guard value > 0, maxValue > 0 else { return 0 }
            if value * 4 > maxValue * 3 { return 4 }
            if value * 2 > maxValue { return 3 }
            if value * 4 > maxValue { return 2 }
            return 1
        }
    }

    /// Weekly totals (sum each 7-day column).
    static func weeklyTotals(_ daily: [Int]) -> [Int] {
        stride(from: 0, to: daily.count, by: SpendActivitySeries.dayCount).map {
            daily[$0..<min($0 + SpendActivitySeries.dayCount, daily.count)].reduce(0, +)
        }
    }

    /// Running cumulative totals across weeks.
    static func cumulativeTotals(_ weekly: [Int]) -> [Int] {
        var sum = 0
        return weekly.map { sum += $0; return sum }
    }

    /// Color for a daily level, blending accent toward the background (Codex's alpha ramp).
    static func color(forLevel level: Int) -> Color {
        // Alphas mirror Codex: empty ~0.14 (dark) and a 4-step active ramp.
        let accent = Color.accentColor
        switch level {
        case 4: return accent
        case 3: return accent.opacity(0.68)
        case 2: return accent.opacity(0.42)
        case 1: return accent.opacity(0.22)
        default: return Color(nsColor: .separatorColor).opacity(0.16)
        }
    }
}

// MARK: - 视图

struct SpendActivityHeatmapView: View {
    let analysis: SpendDashboardModel.ModelAnalysis
    @AppStorage("spendActivityViewMode") private var mode: SpendActivityViewMode = .daily
    /// Cache the 365-day aggregation: recomputing it on every body evaluation (each hover tick
    /// re-evaluates body) is wasted work. Rebuild only when the analysis input changes.
    @State private var cachedSeries: SpendActivitySeries?

    private var series: SpendActivitySeries {
        self.cachedSeries ?? SpendActivitySeries.make(from: self.analysis)
    }

    var body: some View {
        let series = self.series
        let hasActivity = (series.daily.max() ?? 0) > 0
        let totalTokens = series.daily.reduce(0, +)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Token activity"))
                        .font(.headline)
                    if hasActivity {
                        Text("\(UsageFormatter.tokenCountString(totalTokens)) \(L("in the last year"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Picker(L("View"), selection: self.$mode) {
                    ForEach(SpendActivityViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if !hasActivity {
                Text(L("No activity in the last 12 months"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                switch self.mode {
                case .daily:
                    SpendActivityDailyGrid(series: series)
                    self.dailyLegend
                case .weekly:
                    SpendActivityBarGrid(series: series, values: SpendActivityLevels.weeklyTotals(series.daily))
                    self.barCaption(text: L("Each column = 1 week"))
                case .cumulative:
                    SpendActivityBarGrid(
                        series: series,
                        values: SpendActivityLevels.cumulativeTotals(SpendActivityLevels.weeklyTotals(series.daily)))
                    self.barCaption(text: L("Running total"))
                }
            }
        }
        .onAppear { self.cachedSeries = SpendActivitySeries.make(from: self.analysis) }
        .onChange(of: self.analysis) { _, newValue in
            self.cachedSeries = SpendActivitySeries.make(from: newValue)
        }
    }

    private var dailyLegend: some View {
        HStack(spacing: 4) {
            Spacer()
            Text(L("Less"))
            ForEach(0...4, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(SpendActivityLevels.color(forLevel: level))
                    .frame(width: 9, height: 9)
            }
            Text(L("More"))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func barCaption(text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

// MARK: - 每日网格（圆点 + 月份/星期标签）

private struct SpendActivityDailyGrid: View {
    let series: SpendActivitySeries

    private let columns = SpendActivitySeries.weekCount
    private let rows = SpendActivitySeries.dayCount

    /// Hovered cell index (nil when the pointer leaves the grid). Drives the tooltip only; the
    /// Canvas itself does not re-render on hover, so this stays cheap.
    @State private var hoveredIndex: Int?

    var body: some View {
        let levels = SpendActivityLevels.dailyLevels(self.series.daily)
        VStack(alignment: .leading, spacing: 3) {
            self.monthRow
            HStack(alignment: .top, spacing: 4) {
                self.weekdayGutter
                GeometryReader { geo in
                    let pitch = (geo.size.width) / CGFloat(self.columns)
                    let cell = max(min(pitch, (geo.size.height) / CGFloat(self.rows)) - 1.5, 2)
                    Canvas { context, size in
                        let rowPitch = size.height / CGFloat(self.rows)
                        let corner = min(cell * 0.22, 2.5) // GitHub-style slightly rounded squares
                        for index in 0..<(self.columns * self.rows) {
                            guard self.isVisibleCell(index) else { continue }
                            let col = index / self.rows
                            let row = index % self.rows
                            let rect = CGRect(
                                x: CGFloat(col) * pitch + (pitch - cell) / 2,
                                y: CGFloat(row) * rowPitch + (rowPitch - cell) / 2,
                                width: cell,
                                height: cell)
                            context.fill(
                                RoundedRectangle(cornerRadius: corner, style: .continuous).path(in: rect),
                                with: .color(SpendActivityLevels.color(forLevel: levels[index])))
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        self.tooltip(in: geo.size, pitch: pitch)
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            self.hoveredIndex = self.cellIndex(at: location, size: geo.size, pitch: pitch)
                        case .ended:
                            self.hoveredIndex = nil
                        }
                    }
                }
                .aspectRatio(CGFloat(self.columns) / CGFloat(self.rows), contentMode: .fit)
            }
        }
    }

    /// Hide future cells in the current (last) week.
    private func isVisibleCell(_ index: Int) -> Bool {
        guard let date = self.series.date(at: index) else { return false }
        return date <= self.series.today
    }

    /// Maps a pointer location to a grid cell index, or nil when over a future/hidden cell.
    private func cellIndex(at location: CGPoint, size: CGSize, pitch: CGFloat) -> Int? {
        let rowPitch = size.height / CGFloat(self.rows)
        let col = Int(location.x / pitch)
        let row = Int(location.y / rowPitch)
        guard col >= 0, col < self.columns, row >= 0, row < self.rows else { return nil }
        let index = col * self.rows + row
        return self.isVisibleCell(index) ? index : nil
    }

    @ViewBuilder
    private func tooltip(in size: CGSize, pitch: CGFloat) -> some View {
        if let index = self.hoveredIndex,
           let date = self.series.date(at: index)
        {
            let tokens = self.series.daily[index]
            let col = index / self.rows
            let rowPitch = size.height / CGFloat(self.rows)
            // Flip the tooltip to the left once the pointer is past the horizontal midpoint so it
            // never clips the grid's trailing edge.
            let anchorX = CGFloat(col) * pitch + pitch / 2
            let flip = anchorX > size.width * 0.6
            VStack(alignment: .leading, spacing: 1) {
                Text(UsageFormatter.tokenCountString(tokens))
                    .font(.caption.weight(.semibold))
                Text(date, format: .dateTime.month(.abbreviated).day().year())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .fixedSize()
            .offset(
                x: flip ? anchorX - 120 : anchorX + 6,
                y: CGFloat(index % self.rows) * rowPitch - 4)
            .allowsHitTesting(false)
        }
    }

    private var weekdayGutter: some View {
        VStack(spacing: 0) {
            ForEach(0..<self.rows, id: \.self) { row in
                Text(self.weekdayLabel(row))
                    .font(.system(size: 7))
                    .foregroundStyle(.tertiary)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(width: 16)
    }

    private func weekdayLabel(_ row: Int) -> String {
        // Rows start at Sunday (Codex order), but only label a few to avoid clutter.
        switch row {
        case 1: L("Mo")
        case 3: L("We")
        case 5: L("Fr")
        default: ""
        }
    }

    private var monthRow: some View {
        // One label per month, placed over the column containing that month's first day (day <= 7),
        // matching Codex's `month_labels`. Overlapping labels are skipped.
        GeometryReader { geo in
            let pitch = geo.size.width / CGFloat(self.columns)
            ZStack(alignment: .topLeading) {
                ForEach(self.monthMarkers(pitch: pitch), id: \.offset) { marker in
                    Text(marker.label)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .offset(x: marker.offset)
                }
            }
        }
        .frame(height: 12)
        .padding(.leading, 20) // align with the grid (gutter width + spacing)
    }

    private struct MonthMarker {
        let offset: CGFloat
        let label: String
    }

    private func monthMarkers(pitch: CGFloat) -> [MonthMarker] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM"
        var markers: [MonthMarker] = []
        var lastLabel = ""
        for col in 0..<self.columns {
            guard let date = self.series.date(at: col * self.rows) else { continue }
            let day = self.series.calendar.component(.day, from: date)
            guard day <= 7 else { continue }
            let label = formatter.string(from: date)
            guard label != lastLabel else { continue }
            markers.append(MonthMarker(offset: CGFloat(col) * pitch, label: label))
            lastLabel = label
        }
        return markers
    }
}

// MARK: - 每周 / 累计 柱状网格

private struct SpendActivityBarGrid: View {
    let series: SpendActivitySeries
    let values: [Int]

    private let columns = SpendActivitySeries.weekCount

    var body: some View {
        let maxValue = self.values.max() ?? 0
        VStack(alignment: .leading, spacing: 2) {
            Canvas { context, size in
                let pitch = size.width / CGFloat(self.values.count)
                let barWidth = max(pitch * 0.6, 1.5)
                for (index, value) in self.values.enumerated() {
                    guard value > 0, maxValue > 0 else { continue }
                    let height = size.height * CGFloat(value) / CGFloat(maxValue)
                    let rect = CGRect(
                        x: CGFloat(index) * pitch + (pitch - barWidth) / 2,
                        y: size.height - height,
                        width: barWidth,
                        height: height)
                    context.fill(
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous).path(in: rect),
                        with: .color(Color.accentColor.opacity(0.78)))
                }
            }
            .frame(height: 90)
            .frame(maxWidth: .infinity)
        }
        .padding(.leading, 20)
    }
}
