import Foundation

extension SpendDashboardModel {
    /// Half-open instants preserve calendar-day filtering, including DST, without normalizing every turn.
    static func performanceInterval(
        bounds: ClosedRange<Date>, calendar: Calendar, selectedDay: Date?) -> Range<Date>?
    {
        let start = selectedDay.map { calendar.startOfDay(for: $0) } ?? bounds.lowerBound
        let lastDay = selectedDay == nil ? bounds.upperBound : start
        guard bounds.contains(start),
              let end = calendar.date(byAdding: .day, value: 1, to: lastDay), end > start
        else { return nil }
        return start..<end
    }
}
