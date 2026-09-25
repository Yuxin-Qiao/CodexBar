import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct SpendDashboardSessionAndHourlyTests {
    @Test
    func `hourly chart focuses the newest day with spend when no day is selected`() throws {
        let now = Date(timeIntervalSince1970: 1_784_222_400) // 2026-07-16 12:00:00 UTC
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let today = calendar.startOfDay(for: now)
        let olderHour = try #require(calendar.date(byAdding: .day, value: -3, to: now))
        let emptyLaterHour = try #require(calendar.date(byAdding: .hour, value: 1, to: now))
        let input = SpendDashboardModel.ProviderInput(
            id: "codex",
            provider: .codex,
            displayName: "Codex",
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: 30,
                last30DaysCostUSD: 3,
                currencyCode: "USD",
                daily: [
                    Self.entry(day: "2026-07-13", cost: 1, tokens: 10),
                    Self.entry(day: "2026-07-16", cost: 2, tokens: 20),
                ],
                hourly: [
                    CostUsageHourlyEntry(hour: olderHour, totalTokens: 10, costUSD: 1),
                    CostUsageHourlyEntry(hour: now, totalTokens: 20, costUSD: 2),
                    CostUsageHourlyEntry(hour: emptyLaterHour, totalTokens: 0, costUSD: 0),
                ],
                updatedAt: now))

        let group = try #require(SpendDashboardModel.build(
            inputs: [input], requestedDays: 30, now: now, calendar: calendar).groups.first)
        #expect(group.hourlyDay == today)
        #expect(group.hourlyPoints.allSatisfy { calendar.isDate($0.hour, inSameDayAs: today) })
        #expect(group.hourlyPoints.map(\.cost).reduce(0, +) == 2)
        #expect(group.hourlyChartDomain?.lowerBound == today)

        let olderDay = calendar.startOfDay(for: olderHour)
        let selected = try #require(SpendDashboardModel.build(
            inputs: [input], requestedDays: 30, now: now, calendar: calendar, selectedDay: olderDay).groups.first)
        #expect(selected.hourlyDay == olderDay)
        #expect(selected.hourlyPoints.map(\.cost) == [1])
    }

    @Test
    func `session rows prefer title and project over the source name`() throws {
        let now = Date(timeIntervalSince1970: 1_784_222_400)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        func session(_ id: String, title: String?, projectPath: String?) -> CostUsageSessionBreakdown {
            CostUsageSessionBreakdown(
                sessionID: id,
                lastActivity: now,
                inputTokens: 10,
                cachedInputTokens: nil,
                outputTokens: 2,
                totalTokens: 12,
                requestCount: 1,
                costUSD: 1,
                modelBreakdowns: [.init(modelName: "gpt-5.4", costUSD: 1, totalTokens: 12)],
                title: title,
                projectPath: projectPath)
        }
        let input = SpendDashboardModel.ProviderInput(
            id: "codex",
            provider: .codex,
            displayName: "Codex · #1",
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: 36,
                last30DaysCostUSD: 3,
                currencyCode: "USD",
                daily: [Self.entry(day: "2026-07-16", cost: 3, tokens: 36)],
                sessions: [
                    session("a", title: "Fix login bug", projectPath: "/Users/example/Projects/alpha-app"),
                    session("b", title: "  ", projectPath: "/Users/example/Projects/beta-app/"),
                    session("c", title: nil, projectPath: nil),
                ],
                updatedAt: now))
        let model = SpendDashboardModel.build(inputs: [input], requestedDays: 30, now: now, calendar: calendar)
        let rows = try #require(model.groups.first?.sessions)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

        let titled = try #require(byID["codex:a"])
        #expect(titled.headline == "Fix login bug")
        #expect(titled.contextLabels == ["alpha-app", "Codex · #1", "gpt-5.4"])

        let projectOnly = try #require(byID["codex:b"])
        #expect(projectOnly.headline == "beta-app")
        #expect(projectOnly.contextLabels == ["Codex · #1", "gpt-5.4"])

        let bare = try #require(byID["codex:c"])
        #expect(bare.headline == "Codex · #1")
        #expect(bare.contextLabels == ["gpt-5.4"])
    }

    private static func entry(day: String, cost: Double, tokens: Int) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: [.init(modelName: "test-model", costUSD: cost, totalTokens: tokens)])
    }
}
