import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendActivityHeatmapTests {
    @Test
    func `daily levels keep exact boundaries and tolerate Int max`() {
        #expect(SpendActivityLevels.dailyLevels([0, 1, 25, 26, 50, 51, 75, 76, 100]) == [
            0, 1, 1, 2, 2, 3, 3, 4, 4,
        ])
        #expect(SpendActivityLevels.dailyLevels([Int.max, Int.max / 2]) == [4, 2])
    }

    @Test
    func `weekly and cumulative totals saturate instead of overflowing`() {
        let daily = [Int.max, 1, 0, 0, 0, 0, 0, 2]
        let weekly = SpendActivityLevels.weeklyTotals(daily)
        #expect(weekly == [Int.max, 2])
        #expect(SpendActivityLevels.cumulativeTotals(weekly) == [Int.max, Int.max])
    }

    @Test
    func `series uses a fixed Sunday first 52 week window`() throws {
        let calendar = Self.calendar
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 5)))
        let previousDay = try #require(calendar.date(byAdding: .day, value: -1, to: now))
        let futureDay = try #require(calendar.date(byAdding: .day, value: 1, to: now))
        let series = SpendActivitySeries.make(
            from: [
                .init(day: previousDay, totalTokens: 10),
                .init(day: now, totalTokens: 20),
                .init(day: futureDay, totalTokens: 30),
            ],
            now: now,
            calendar: calendar)

        #expect(series.daily.count == 52 * 7)
        #expect(calendar.component(.weekday, from: series.start) == 1)
        #expect(series.daily.reduce(0, +) == 30)
        #expect(series.date(at: series.daily.count - 1)! > series.today)
    }

    @Test
    func `token activity spans a year without widening the spend chart`() throws {
        let now = try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 7, day: 16)))
        let oldDay = "2025-08-01"
        let first = Self.snapshot(entries: [
            Self.entry(day: oldDay, cost: 2, tokens: 40),
            Self.entry(day: "2026-07-16", cost: 3, tokens: 10),
            Self.entry(day: "2026-08-01", cost: 4, tokens: 100),
        ])
        let second = Self.snapshot(entries: [
            Self.entry(day: oldDay, cost: 1, tokens: 60),
            Self.entry(day: "2025-07-15", cost: 1, tokens: 200),
            Self.entry(day: "invalid", cost: 1, tokens: 300),
            Self.entry(day: "2026-07-15", cost: 1, tokens: -1),
        ])
        let model = SpendDashboardModel.build(
            inputs: [
                .init(id: "first", provider: .claude, displayName: "Claude", snapshot: first),
                .init(id: "second", provider: .openai, displayName: "OpenAI", snapshot: second),
            ],
            requestedDays: 30,
            now: now,
            calendar: Self.calendar)

        let oldDate = try #require(Self.calendar.date(from: DateComponents(year: 2025, month: 8, day: 1)))
        #expect(model.tokenActivity == [
            .init(day: oldDate, totalTokens: 100),
            .init(day: now, totalTokens: 10),
        ])
        #expect(model.groups.first?.dailyPoints.map(\.day) == [now])
    }

    @Test
    func `weekday labels and cells share the same row pitch`() {
        let frame = SpendActivityGridGeometry.gridFrame(containerWidth: 1088)
        let pitch = frame.width / CGFloat(SpendActivitySeries.weekCount)

        #expect(SpendActivityGridGeometry.weekdayCenter(row: 1, rowPitch: pitch) == pitch * 1.5)
        #expect(SpendActivityGridGeometry.weekdayCenter(row: 3, rowPitch: pitch) == pitch * 3.5)
        #expect(SpendActivityGridGeometry.weekdayCenter(row: 5, rowPitch: pitch) == pitch * 5.5)
        #expect(frame.height == pitch * 7)
    }

    @Test
    func `tooltip stays beside the hovered cell and clamps only at the edge`() {
        let gridWidth: CGFloat = 1000
        let width = SpendActivityGridGeometry.tooltipWidth
        let centered = SpendActivityGridGeometry.tooltipCenterX(
            anchorX: 500,
            tooltipWidth: width,
            gridWidth: gridWidth)
        let trailing = SpendActivityGridGeometry.tooltipCenterX(
            anchorX: 995,
            tooltipWidth: width,
            gridWidth: gridWidth)

        #expect(centered == 500)
        #expect(trailing > 900)
        #expect(trailing <= gridWidth - width / 2)
        #expect(SpendActivityGridGeometry.tooltipOriginY(
            anchorY: 10,
            tooltipHeight: 50,
            gridHeight: 130) > 10)
        #expect(SpendActivityGridGeometry.tooltipOriginY(
            anchorY: 120,
            tooltipHeight: 50,
            gridHeight: 130) < 70)
    }

    @Test
    func `weekday and date formatting follow the selected resource locale`() throws {
        let date = try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 8, day: 1)))
        let english = Locale(identifier: "en_US")
        let chinese = Locale(identifier: "zh_Hans")

        #expect(SpendActivityWeekday.label(for: 1, locale: english) == "Mon")
        #expect(SpendActivityWeekday.label(for: 3, locale: english) == "Wed")
        #expect(SpendActivityWeekday.label(for: 5, locale: english) == "Fri")
        #expect(SpendActivityDateFormatting.mediumDateString(date, locale: english).contains("Aug"))
        #expect(!SpendActivityDateFormatting.mediumDateString(date, locale: english).contains("年"))
        #expect(SpendActivityDateFormatting.mediumDateString(date, locale: chinese).contains("年"))
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func snapshot(entries: [CostUsageDailyReport.Entry]) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            currencyCode: "USD",
            historyDays: 365,
            daily: entries,
            updatedAt: Date(timeIntervalSince1970: 1_784_179_200))
    }

    private static func entry(day: String, cost: Double?, tokens: Int?) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: [])
    }
}
