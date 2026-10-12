import CodexBarCore
import Foundation

extension SpendDashboardModel {
    static func visibleInputs(
        _ inputs: [ProviderInput],
        hiddenSourceIDs: Set<String>,
        hideNativeCodexWhenOpenCodexPresent: Bool) -> [ProviderInput]
    {
        var filtered = inputs.filter { !hiddenSourceIDs.contains($0.id) }
        // Provider-specific by design: only a canonical OpenCodex Codex row may replace native Codex rows.
        let hasOpenCodex = filtered.contains {
            $0.id == Self.openCodexSourceID &&
                $0.provider == .codex &&
                $0.sourceKind == .openCodex
        }
        if hideNativeCodexWhenOpenCodexPresent, hasOpenCodex {
            filtered.removeAll { $0.sourceKind == .native && $0.provider == .codex }
        }
        return filtered
    }
}

func spendDashboardEmptyDetailGroup(currencyCode: String) -> SpendDashboardModel.CurrencyGroup {
    SpendDashboardModel.CurrencyGroup(
        currencyCode: currencyCode,
        providers: [],
        models: [],
        dailyPoints: [],
        totalTokens: nil,
        totalCost: nil,
        coveredDayCount: 0,
        chartDomain: Date.distantPast...Date.distantPast,
        modelHistoryCompleteness: .incomplete)
}

func spendDashboardShouldRetainDetails(
    previous: CostUsageTokenSnapshot,
    next: CostUsageTokenSnapshot) -> Bool
{
    if !next.historyCoverageIsEstablished { return true }
    let hadProjects = previous.projectBreakdownAvailability == .complete
        || (previous.projectBreakdownAvailability == .notRequested && !previous.projects.isEmpty)
    let hadSessions = previous.sessionBreakdownAvailability == .complete
        || (previous.sessionBreakdownAvailability == .notRequested && !previous.sessions.isEmpty)
    return (hadProjects && next.projectBreakdownAvailability != .complete)
        || (hadSessions && next.sessionBreakdownAvailability != .complete)
}

func spendDashboardBreakdownAvailability(
    _ values: [CostUsageBreakdownAvailability]) -> CostUsageBreakdownAvailability
{
    guard !values.isEmpty else { return .notRequested }
    return values.allSatisfy { $0 == .complete } ? .complete : .unavailable
}

func spendDashboardDetailMessage(
    availability: CostUsageBreakdownAvailability,
    hasRows: Bool,
    isRefreshing: Bool,
    hasFailedSources: Bool,
    isStale: Bool) -> String?
{
    if hasRows {
        if isRefreshing { return "\(L("section_refreshing")) · \(L("Showing the last available details."))" }
        if hasFailedSources { return "\(L("Refresh failures")) · \(L("Showing the last available details."))" }
        if isStale { return L("Showing the last available details.") }
        return nil
    }
    if isRefreshing { return L("Loading details…") }
    if hasFailedSources { return L("Details unavailable. Refresh to try again.") }
    if availability != .complete { return L("Details unavailable. Refresh to try again.") }
    if isStale { return L("Showing the last available details.") }
    return L("No records in this time range.")
}

func spendDashboardDetailUpdatedText(_ date: Date, timeZone: TimeZone) -> String {
    var format = Date.FormatStyle(date: .abbreviated, time: .shortened)
    format.timeZone = timeZone
    format.locale = codexBarLocalizedLocale()
    return L("Updated %@", date.formatted(format))
}

func spendDashboardSupportsCodexDetails(
    sources: [SpendSourcePublication],
    hiddenSourceIDs: Set<String>,
    hideNativeCodexWhenOpenCodexPresent _: Bool) -> Bool
{
    let visible = sources.filter { !hiddenSourceIDs.contains($0.id) }
    // Provider-specific by design: these capabilities and refresh failures belong to native Codex histories.
    return visible.contains { $0.provider == .codex && $0.role == .subscription }
}

func spendDashboardDetailSourcesHaveFailed(
    _ sources: [SpendSourcePublication],
    hiddenSourceIDs: Set<String>) -> Bool
{
    sources.contains {
        $0.provider == .codex && $0.role == .subscription && !hiddenSourceIDs.contains($0.id)
            && ($0.state == .unavailable || $0.state == .staleLastKnown)
    }
}
