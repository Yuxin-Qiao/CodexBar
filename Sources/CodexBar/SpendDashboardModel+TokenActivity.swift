import CodexBarCore
import Foundation

extension SpendDashboardModel {
    static func tokenActivity(
        inputs: [ProviderInput],
        now: Date,
        calendar: Calendar) -> [TokenActivityPoint]
    {
        guard !inputs.isEmpty else { return [] }
        let bounds = Self.bounds(days: Self.tokenActivityDayCount, now: now, calendar: calendar)
        let summaries = inputs.map {
            Self.tokenActivityInputSummary(input: $0, bounds: bounds, calendar: calendar)
        }
        return (0..<Self.tokenActivityDayCount).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: bounds.lowerBound) else {
                return nil
            }
            var total = 0
            for summary in summaries {
                guard let tokens = summary.tokens(on: day) else {
                    return TokenActivityPoint(day: day, totalTokens: nil)
                }
                let addition = total.addingReportingOverflow(tokens)
                total = addition.overflow ? Int.max : addition.partialValue
            }
            return TokenActivityPoint(day: day, totalTokens: total)
        }
    }

    static func tokenActivityInputSummary(
        input: ProviderInput,
        bounds: ClosedRange<Date>,
        calendar: Calendar) -> SpendTokenActivityInputSummary
    {
        let annualInput = ProviderInput(
            id: input.id,
            provider: input.provider,
            displayName: input.displayName,
            modelProviderName: input.modelProviderName,
            snapshot: input.tokenActivitySnapshot)
        let annual = Self.tokenActivitySnapshotSummary(input: annualInput, bounds: bounds, calendar: calendar)
        guard input.snapshot != input.tokenActivitySnapshot else { return annual }

        let recentInput = ProviderInput(
            id: input.id,
            provider: input.provider,
            displayName: input.displayName,
            modelProviderName: input.modelProviderName,
            snapshot: input.snapshot)
        let recent = Self.tokenActivitySnapshotSummary(input: recentInput, bounds: bounds, calendar: calendar)
        var totalsByDay = annual.totalsByDay
        var invalidDays = annual.invalidDays
        var zeroKnownDays = annual.zeroKnownDays
        for day in recent.coveredDays {
            totalsByDay.removeValue(forKey: day)
            invalidDays.remove(day)
            zeroKnownDays.remove(day)
            if let tokens = recent.totalsByDay[day] {
                totalsByDay[day] = tokens
            }
            if recent.invalidDays.contains(day) {
                invalidDays.insert(day)
            }
            if recent.zeroKnownDays.contains(day) {
                zeroKnownDays.insert(day)
            }
        }
        return SpendTokenActivityInputSummary(
            coveredDays: annual.coveredDays.union(recent.coveredDays),
            totalsByDay: totalsByDay,
            invalidDays: invalidDays,
            zeroKnownDays: zeroKnownDays)
    }

    static func tokenActivitySnapshotSummary(
        input: ProviderInput,
        bounds: ClosedRange<Date>,
        calendar: Calendar) -> SpendTokenActivityInputSummary
    {
        let coveredInterval = Self.coverageInterval(
            input: input,
            bounds: bounds,
            displayCalendar: calendar)
        let coveredDays = Self.days(in: coveredInterval, calendar: calendar)
        let sourceCoverage = Self.sourceCoverageInterval(input: input, displayCalendar: calendar)
        var totalsByDay: [Date: Int] = [:]
        var invalidDays: Set<Date> = []
        var hasUnplacedTokens = false
        for entry in input.snapshot.daily {
            guard let day = Self.day(entry.date, provider: input.provider, displayCalendar: calendar) else {
                hasUnplacedTokens = hasUnplacedTokens || !Self.hasProvenZeroTokens(entry)
                continue
            }
            guard sourceCoverage.contains(day) else { continue }
            guard let tokens = Self.nonnegative(entry.totalTokens) else {
                invalidDays.insert(day)
                continue
            }
            guard !invalidDays.contains(day) else { continue }
            let addition = (totalsByDay[day] ?? 0).addingReportingOverflow(tokens)
            if addition.overflow {
                totalsByDay.removeValue(forKey: day)
                invalidDays.insert(day)
            } else {
                totalsByDay[day] = addition.partialValue
            }
        }

        // A successful scan that found no sessions is confirmed zero activity: every covered day
        // renders as zero instead of unavailable. Nonempty histories must still reconcile their
        // aggregate against the daily entries.
        let confirmedZeroHistory = input.snapshot.daily.isEmpty
            && input.snapshot.last30DaysTokens == nil
        let hasCompleteHistory = confirmedZeroHistory
            || Self.hasCompleteTokenHistory(input, displayCalendar: calendar)
        let aggregateIsInconsistent = input.snapshot.last30DaysTokens != nil && !hasCompleteHistory
        if hasUnplacedTokens || aggregateIsInconsistent {
            invalidDays.formUnion(coveredDays)
        }
        return SpendTokenActivityInputSummary(
            coveredDays: coveredDays,
            totalsByDay: totalsByDay,
            invalidDays: invalidDays,
            zeroKnownDays: hasCompleteHistory ? coveredDays : [])
    }

    static func days(in interval: ClosedRange<Date>?, calendar: Calendar) -> Set<Date> {
        guard let interval else { return [] }
        var result: Set<Date> = []
        var day = interval.lowerBound
        while day <= interval.upperBound {
            result.insert(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return result
    }

    struct SpendTokenActivityInputSummary {
        let coveredDays: Set<Date>
        let totalsByDay: [Date: Int]
        let invalidDays: Set<Date>
        let zeroKnownDays: Set<Date>

        func tokens(on day: Date) -> Int? {
            guard self.coveredDays.contains(day), !self.invalidDays.contains(day) else { return nil }
            if let tokens = self.totalsByDay[day] {
                return tokens
            }
            return self.zeroKnownDays.contains(day) ? 0 : nil
        }
    }
}
