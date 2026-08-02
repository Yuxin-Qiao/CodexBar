import Foundation

private struct SpendChartActivityDay {
    let day: Date
    let tokens: Double
    let spend: Double
}

extension SpendDashboardModel {
    static func allModelChartDomain(
        analysis: ModelAnalysis,
        bounds: ClosedRange<Date>,
        calendar: Calendar) -> ClosedRange<Date>
    {
        let activityDays = Dictionary(grouping: analysis.dailyValues, by: {
            calendar.startOfDay(for: $0.day)
        })
        .compactMap { day, values -> SpendChartActivityDay? in
            let tokens = values.reduce(0.0) { partial, value in
                if let total = value.totalTokens, total > 0 {
                    return partial + Double(total)
                }
                // Reasoning is a sub-bucket of output and must not be added again.
                return partial + [
                    value.inputTokens,
                    value.outputTokens,
                    value.cacheReadTokens,
                    value.cacheCreationTokens,
                ].reduce(0.0) { subtotal, amount in
                    subtotal + Double(max(0, amount ?? 0))
                }
            }
            let spend = values.reduce(0.0) { partial, value in
                partial + max(0, value.estimatedCost ?? 0)
            }
            guard tokens > 0 || spend > 0 else { return nil }
            return SpendChartActivityDay(day: day, tokens: tokens, spend: spend)
        }
        .sorted { $0.day < $1.day }
        let focusedDays = Self.droppingSparseLeadingActivity(
            activityDays,
            calendar: calendar)
        guard let firstActiveDay = focusedDays.first?.day,
              let lastActiveDay = focusedDays.last?.day
        else {
            let fallbackStart = calendar.date(
                byAdding: .day,
                value: -6,
                to: bounds.upperBound) ?? bounds.upperBound
            let fallbackEnd = calendar.date(
                byAdding: .day,
                value: 1,
                to: bounds.upperBound) ?? bounds.upperBound
            return max(bounds.lowerBound, fallbackStart)...fallbackEnd
        }

        let observedDays = max(
            1,
            (calendar.dateComponents(
                [.day],
                from: firstActiveDay,
                to: lastActiveDay).day ?? 0) + 1)
        let paddingDays = min(14, max(1, Int(ceil(Double(observedDays) * 0.04))))
        var start = max(
            bounds.lowerBound,
            calendar.date(byAdding: .day, value: -paddingDays, to: firstActiveDay) ?? firstActiveDay)
        var lastVisibleDay = min(
            bounds.upperBound,
            calendar.date(byAdding: .day, value: paddingDays, to: lastActiveDay) ?? lastActiveDay)

        let visibleDays = max(
            1,
            (calendar.dateComponents([.day], from: start, to: lastVisibleDay).day ?? 0) + 1)
        if visibleDays < 7 {
            let missingDays = 7 - visibleDays
            let earlierStart = calendar.date(byAdding: .day, value: -missingDays, to: start) ?? start
            start = max(bounds.lowerBound, earlierStart)
            let expandedDays = max(
                1,
                (calendar.dateComponents([.day], from: start, to: lastVisibleDay).day ?? 0) + 1)
            if expandedDays < 7 {
                let laterEnd = calendar.date(
                    byAdding: .day,
                    value: 7 - expandedDays,
                    to: lastVisibleDay) ?? lastVisibleDay
                lastVisibleDay = min(bounds.upperBound, laterEnd)
            }
        }

        let end = calendar.date(byAdding: .day, value: 1, to: lastVisibleDay) ?? lastVisibleDay
        return start...end
    }

    /// Cumulative history occasionally contains one or two tiny legacy samples followed by
    /// months of nothing. Keeping those samples on a calendar axis compresses the useful recent
    /// history into a narrow strip. Drop only a leading segment that is separated by a long gap,
    /// contains very few active days, and contributes no more than 5% of either tokens or spend.
    /// The samples remain in rankings and totals; this affects chart framing only.
    private static func droppingSparseLeadingActivity(
        _ days: [SpendChartActivityDay],
        calendar: Calendar) -> [SpendChartActivityDay]
    {
        guard days.count >= 4 else { return days }
        let totalTokens = days.reduce(0.0) { $0 + $1.tokens }
        let totalSpend = days.reduce(0.0) { $0 + $1.spend }
        var lowerBound = 0

        while days.count - lowerBound >= 4 {
            let visible = days[lowerBound...]
            let prefixCountLimit = max(2, Int(ceil(Double(visible.count) * 0.10)))
            var splitIndex: Int?
            for candidate in visible.indices.dropLast() {
                let gap = Self.dayGap(
                    days[candidate].day,
                    days[candidate + 1].day,
                    calendar: calendar)
                guard gap >= 21 else { continue }
                let prefix = days[lowerBound...candidate]
                let prefixTokens = prefix.reduce(0.0) { $0 + $1.tokens }
                let prefixSpend = prefix.reduce(0.0) { $0 + $1.spend }
                let tokenShare = totalTokens > 0 ? prefixTokens / totalTokens : 0
                let spendShare = totalSpend > 0 ? prefixSpend / totalSpend : 0
                if prefix.count <= prefixCountLimit,
                   tokenShare <= 0.05,
                   spendShare <= 0.05
                {
                    splitIndex = candidate
                    break
                }
            }
            guard let splitIndex else { break }
            lowerBound = splitIndex + 1
        }

        return Array(days[lowerBound...])
    }

    private static func dayGap(
        _ lhs: Date,
        _ rhs: Date,
        calendar: Calendar) -> Int
    {
        max(0, calendar.dateComponents([.day], from: lhs, to: rhs).day ?? 0)
    }
}
