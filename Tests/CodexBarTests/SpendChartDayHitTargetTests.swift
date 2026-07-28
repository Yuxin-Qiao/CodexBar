import Foundation
import Testing
@testable import CodexBar

struct SpendChartDayHitTargetTests {
    @Test
    func `dense days receive a minimum clickable radius`() {
        let days = Self.days(count: 3)
        let positions = Dictionary(uniqueKeysWithValues: zip(days, [CGFloat(100), 103, 106]))

        let selected = SpendChartDayHitTarget.nearestDay(
            toX: 113,
            days: days,
            position: { positions[$0] })

        #expect(selected == days[2])
    }

    @Test
    func `sparse days use midpoint-sized targets without capturing distant empty space`() {
        let days = Self.days(count: 2)
        let positions = Dictionary(uniqueKeysWithValues: zip(days, [CGFloat(20), 60]))

        #expect(SpendChartDayHitTarget.nearestDay(
            toX: 39,
            days: days,
            position: { positions[$0] }) == days[0])
        #expect(SpendChartDayHitTarget.nearestDay(
            toX: 100,
            days: days,
            position: { positions[$0] }) == nil)
    }

    @Test
    func `space between active days belongs continuously to the nearest day`() {
        let days = Self.days(count: 2)
        let positions = Dictionary(uniqueKeysWithValues: zip(days, [CGFloat(20), 80]))

        #expect(SpendChartDayHitTarget.nearestDay(
            toX: 49,
            days: days,
            position: { positions[$0] }) == days[0])
        #expect(SpendChartDayHitTarget.nearestDay(
            toX: 51,
            days: days,
            position: { positions[$0] }) == days[1])
    }

    @Test
    func `hit testing follows rendered x order rather than input order`() {
        let days = Self.days(count: 3)
        let positions = [
            days[0]: CGFloat(80),
            days[1]: CGFloat(20),
            days[2]: CGFloat(50),
        ]

        #expect(SpendChartDayHitTarget.nearestDay(
            toX: 24,
            days: days,
            position: { positions[$0] }) == days[1])
    }

    @Test
    func `hover retains the current day inside the neighboring boundary hysteresis`() {
        let days = Self.days(count: 2)
        let positions = Dictionary(uniqueKeysWithValues: zip(days, [CGFloat(20), 80]))

        let selected = SpendChartDayHoverResolver.resolvedDay(
            toX: 54,
            days: days,
            currentDay: days[0],
            position: { positions[$0] })

        // The geometric midpoint is 50, but the 7.2-point hysteresis keeps the first day stable.
        #expect(selected == days[0])
    }

    @Test
    func `hover changes after the pointer clearly enters the neighboring lane`() {
        let days = Self.days(count: 2)
        let positions = Dictionary(uniqueKeysWithValues: zip(days, [CGFloat(20), 80]))

        let selected = SpendChartDayHoverResolver.resolvedDay(
            toX: 58,
            days: days,
            currentDay: days[0],
            position: { positions[$0] })

        #expect(selected == days[1])
    }

    @Test
    func `hover catches up immediately across multiple columns`() {
        let days = Self.days(count: 4)
        let positions = Dictionary(uniqueKeysWithValues: zip(days, [CGFloat(20), 50, 80, 110]))

        let selected = SpendChartDayHoverResolver.resolvedDay(
            toX: 109,
            days: days,
            currentDay: days[0],
            position: { positions[$0] })

        #expect(selected == days[3])
    }

    private static func days(count: Int) -> [Date] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return (0..<count).map { start.addingTimeInterval(Double($0) * 86400) }
    }
}
