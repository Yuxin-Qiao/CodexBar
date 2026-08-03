import CodexBarCore

extension UsageMenuCardView.Model {
    static func sessionEquivalentDetail(
        input: Input,
        weeklyWindow: RateWindow,
        weeklyWindowID: String?) -> UsagePaceText.SessionEquivalentDetail?
    {
        guard let forecast = input.sessionEquivalentForecast,
              forecast.applies(to: weeklyWindow, windowID: weeklyWindowID)
        else {
            return nil
        }
        return UsagePaceText.sessionEquivalentDetail(forecast: forecast)
    }

    static func codexRateMetrics(
        input: Input,
        projection: CodexConsumerProjection,
        percentStyle: PercentStyle) -> [Metric]
    {
        projection.visibleRateLanes.compactMap { lane in
            guard let window = projection.rateWindow(for: lane) else { return nil }

            let title = CodexConsumerProjection.rateTitle(
                lane: lane,
                windowMinutes: window.windowMinutes,
                sessionLabel: input.metadata.sessionLabel,
                weeklyLabel: input.metadata.weeklyLabel)
            let id: String
            let paceDetail: PaceDetail?
            switch lane {
            case .session:
                id = "primary"
                paceDetail = window.windowMinutes == CodexConsumerProjection.sessionWindowMinutes
                    ? Self.sessionPaceDetail(
                        provider: input.provider,
                        window: window,
                        now: input.now,
                        showUsed: input.usageBarsShowUsed)
                    : nil
            case .weekly:
                id = "secondary"
                paceDetail = window.windowMinutes == CodexConsumerProjection.weeklyWindowMinutes
                    ? Self.weeklyPaceDetail(
                        provider: input.provider,
                        window: window,
                        now: input.now,
                        pace: Self.standardWeeklyPace(input: input, window: window),
                        showUsed: input.usageBarsShowUsed)
                    : nil
            case .monthly:
                id = "monthly"
                paceDetail = nil
            }

            return Metric(
                id: id,
                title: title,
                percent: Self.clamped(input.usageBarsShowUsed ? window.usedPercent : window.remainingPercent),
                percentStyle: percentStyle,
                resetText: Self.resetText(for: window, style: input.resetTimeDisplayStyle, now: input.now),
                detailText: nil,
                detailLeftText: paceDetail?.leftLabel,
                detailRightText: paceDetail?.rightLabel,
                pacePercent: paceDetail?.pacePercent,
                paceOnTop: paceDetail?.paceOnTop ?? true,
                warningMarkerPercents: Self.warningMarkerPercents(
                    thresholds: lane.quotaWarningWindow.flatMap { input.quotaWarningThresholds[$0] },
                    showUsed: input.usageBarsShowUsed),
                workdayMarkerPercents: lane == .weekly
                    ? workDayMarkerPercents(
                        workDays: input.workDaysPerWeek,
                        windowMinutes: window.windowMinutes)
                    : [],
                sessionEquivalentDetail: lane == .weekly
                    ? Self.sessionEquivalentDetail(input: input, weeklyWindow: window, weeklyWindowID: nil)
                    : nil)
        }
    }
}
