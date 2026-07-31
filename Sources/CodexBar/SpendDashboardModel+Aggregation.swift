import CodexBarCore
import Foundation

extension SpendDashboardModel {
    struct ClassifiedInput {
        let currencyCode: String
        let input: ProviderInput
        let costMultiplier: Double
    }

    struct InputSummary {
        let input: ProviderInput
        let costMultiplier: Double
        let entries: [WindowEntry]
        let totalTokens: Int?
        let totalCost: Double?
        let coveredInterval: ClosedRange<Date>?
        let coveredDayCount: Int
        let projectCount: Int?
        let sessionCount: Int?
        let hasInvalidCostHistory: Bool
    }

    struct WindowEntry {
        let day: Date
        let entry: CostUsageDailyReport.Entry
    }

    // MARK: - Aggregation helpers

    //
    // Pure numeric/date helpers that do not touch the private `InputSummary`/`ModelRange`
    // plumbing. Kept in a separate file to stay within the file-length lint budget; the
    // `private` aggregation pipeline in `SpendDashboardModel.swift` calls these via `Self`.

    static func addAvailable(_ value: Int?, to current: Int?) -> Int? {
        guard let value else { return current }
        return (current ?? 0).addingReportingOverflow(value).overflow
            ? current
            : (current ?? 0) + value
    }

    static func addAvailableCost(_ value: Double?, to current: Double?) -> Double? {
        guard let value = validCost(value) else { return current }
        let result = (current ?? 0) + value
        return result.isFinite ? result : current
    }

    static func bounds(days: Int, now: Date, calendar: Calendar) -> ClosedRange<Date> {
        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        return start...end
    }

    static func gregorianCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func chartDomain(bounds: ClosedRange<Date>, calendar: Calendar) -> ClosedRange<Date> {
        let end = calendar.date(byAdding: .day, value: 1, to: bounds.upperBound) ?? bounds.upperBound
        return bounds.lowerBound...end
    }

    static func dayCount(in interval: ClosedRange<Date>?, calendar: Calendar) -> Int {
        guard let interval else { return 0 }
        return (calendar.dateComponents([.day], from: interval.lowerBound, to: interval.upperBound).day ?? 0) + 1
    }

    static func currencyCode(_ rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return value.isEmpty ? "XXX" : value
    }

    static func validCost(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func nonnegative(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    static func safeCostSum(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        var result = 0.0
        for value in values {
            result += value
            guard result.isFinite else { return nil }
        }
        return result
    }

    static func completeCostSum(_ values: [Double?]) -> Double? {
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        return self.safeCostSum(values.compactMap(\.self))
    }

    /// Sums the providers that *have* a cost figure, ignoring those without one (e.g. a provider
    /// with no local cost history). One cost-less provider must not void the whole currency's
    /// spend total; it is still surfaced individually as "unavailable". Returns nil only when no
    /// provider contributes a cost.
    static func availableCostSum(_ values: [Double?]) -> Double? {
        let present = values.compactMap(\.self)
        guard !present.isEmpty else { return nil }
        return self.safeCostSum(present)
    }

    /// Sums the token values that were actually observed. Missing source totals remain visible on
    /// their individual rows, but do not turn the dashboard-wide "Tracked tokens" subtotal into
    /// an em dash.
    static func availableIntSum(_ values: [Int?]) -> Int? {
        self.safeIntSum(values.compactMap(\.self))
    }

    static func safeIntSum(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        var result = 0
        for value in values {
            let addition = result.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            result = addition.partialValue
        }
        return result
    }

    static func completeIntSum(_ values: [Int?]) -> Int? {
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        return self.safeIntSum(values.compactMap(\.self))
    }

    static func add(_ value: Int, to current: Int?, overflowed: inout Bool) -> Int? {
        guard !overflowed, let current else { return nil }
        let addition = current.addingReportingOverflow(value)
        if addition.overflow {
            overflowed = true
            return nil
        }
        return addition.partialValue
    }

    static func add(_ value: Double, to current: Double?, overflowed: inout Bool) -> Double? {
        guard !overflowed, let current else { return nil }
        let result = current + value
        guard result.isFinite else {
            overflowed = true
            return nil
        }
        return result
    }

    // MARK: - Coverage / day bucketing

    static func coverageInterval(
        input: ProviderInput,
        bounds: ClosedRange<Date>,
        displayCalendar: Calendar) -> ClosedRange<Date>?
    {
        guard input.snapshot.historyCoverageIsEstablished else { return nil }
        let sourceCoverage = Self.sourceCoverageInterval(input: input, displayCalendar: displayCalendar)
        let overlapStart = max(bounds.lowerBound, sourceCoverage.lowerBound)
        let overlapEnd = min(bounds.upperBound, sourceCoverage.upperBound)
        guard overlapStart <= overlapEnd else { return nil }
        return overlapStart...overlapEnd
    }

    static func sourceCoverageInterval(
        input: ProviderInput,
        displayCalendar: Calendar) -> ClosedRange<Date>
    {
        let bucketCalendar = Self.bucketCalendar(for: input.provider, displayCalendar: displayCalendar)
        let bucketEnd = bucketCalendar.startOfDay(for: input.snapshot.updatedAt)
        let scanEnd = displayCalendar.startOfDay(for: bucketEnd)
        let scanDays = max(1, input.snapshot.historyDays)
        let bucketStart = bucketCalendar.date(byAdding: .day, value: -(scanDays - 1), to: bucketEnd) ?? bucketEnd
        let scanStart = displayCalendar.startOfDay(for: bucketStart)
        return scanStart...scanEnd
    }

    static func commonCoverageDayCount(summaries: [InputSummary], calendar: Calendar) -> Int {
        guard let first = summaries.first?.coveredInterval else { return 0 }
        var intersection = first
        for summary in summaries.dropFirst() {
            guard let interval = summary.coveredInterval else { return 0 }
            let start = max(intersection.lowerBound, interval.lowerBound)
            let end = min(intersection.upperBound, interval.upperBound)
            guard start <= end else { return 0 }
            intersection = start...end
        }
        return Self.dayCount(in: intersection, calendar: calendar)
    }

    static func day(
        _ rawValue: String,
        provider: UsageProvider,
        displayCalendar: Calendar) -> Date?
    {
        let bytes = Array(rawValue.utf8)
        let digitIndices = [0, 1, 2, 3, 5, 6, 8, 9]
        guard bytes.count == 10,
              bytes[4] == 45,
              bytes[7] == 45,
              digitIndices.allSatisfy({ (48...57).contains(bytes[$0]) })
        else { return nil }
        let parts = rawValue.split(separator: "-")
        let bucketCalendar = Self.bucketCalendar(for: provider, displayCalendar: displayCalendar)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let date = bucketCalendar.date(from: DateComponents(year: year, month: month, day: day))
        else { return nil }
        guard bucketCalendar.dateComponents([.year, .month, .day], from: date) == DateComponents(
            year: year,
            month: month,
            day: day)
        else { return nil }
        return displayCalendar.startOfDay(for: date)
    }

    static func bucketCalendar(for provider: UsageProvider, displayCalendar: Calendar) -> Calendar {
        guard provider == .mistral else { return displayCalendar }
        // Mistral labels both daily buckets and snapshot coverage by UTC day. Map each UTC boundary into the
        // containing local dashboard day instead of reinterpreting the label as a local date.
        return self.gregorianCalendar(timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt)
    }
}
