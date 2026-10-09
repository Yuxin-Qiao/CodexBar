import CodexBarCore
import Foundation

/// Observed configuration usage, not a benchmark of the agent's ability to complete tasks.
struct SpendAgentProfile: Identifiable, Equatable, Sendable {
    struct Configuration: Hashable, Sendable {
        let sourceID: String
        let model: String?
        let reasoningEffort: String?
    }

    let id: Configuration
    let sourceName: String
    let performance: CostUsageTurnPerformanceSummary
    /// Retain raw observations so harness totals do not average configuration medians or rates.
    let samples: [CostUsageTurnPerformanceSample]
    /// Re-ranked evidence rows, including sessions beyond the dashboard's default 50-row limit.
    /// Their timing is scoped to this configuration; their costs still describe entire sessions.
    let sessions: [SpendDashboardModel.SessionRow]
    let cacheSampleCount: Int
    let historyScanIsPartial: Bool

    static let minimumCacheSamples = 5
    static let maximumCacheScore = 25.0
    static let cacheScoreRuleVersion = "cache-reuse-v1"

    var cacheScore: Double? {
        guard self.cacheSampleCount >= Self.minimumCacheSamples,
              let fraction = self.performance.details.cachedInputFraction else { return nil }
        return fraction * Self.maximumCacheScore
    }

    var modelName: String {
        self.id.model ?? L("Unknown model")
    }

    var effortName: String {
        self.id.reasoningEffort ?? L("Unknown reasoning effort")
    }

    func displaySourceName(hidePersonalInfo: Bool) -> String {
        hidePersonalInfo ? "Codex" : self.sourceName
    }

    static func build(
        summaries: [SpendDashboardModel.InputSummary],
        sessions: [SpendDashboardModel.SessionRow],
        bounds: ClosedRange<Date>,
        calendar: Calendar,
        selectedDay: Date?) -> [Self]
    {
        var observations: [Configuration: [String: [CostUsageTurnPerformanceSample]]] = [:]
        var sources: [String: SpendDashboardModel.ProviderInput] = [:]
        // Provider-specific by design: only the native Codex ledger provides validated completed-turn timing.
        for summary in summaries where summary.input.provider == .codex && summary.input.sourceKind == .native {
            let input = summary.input
            sources[input.id] = input
            for session in input.snapshot.sessions {
                for sample in session.turnPerformanceSamples {
                    let day = calendar.startOfDay(for: sample.completedAt)
                    guard bounds.contains(day), selectedDay == nil || selectedDay == day else { continue }
                    let key = Configuration(
                        sourceID: input.id,
                        model: sample.model,
                        reasoningEffort: sample.reasoningEffort)
                    observations[key, default: [:]]["\(input.id):\(session.sessionID)", default: []].append(sample)
                }
            }
        }
        return observations.compactMap { key, bySession -> Self? in
            let samples = bySession.keys.sorted().flatMap { bySession[$0] ?? [] }
            guard let source = sources[key.sourceID],
                  let performance = CostUsageTurnPerformanceSummary(samples: samples) else { return nil }
            let evidence = sessions.compactMap { row -> SpendDashboardModel.SessionRow? in
                guard let matchingSamples = bySession[row.id] else { return nil }
                var scopedRow = row
                scopedRow.turnPerformance = CostUsageTurnPerformanceSummary(samples: matchingSamples)
                return scopedRow
            }.enumerated().map { index, row in
                var ranked = row
                ranked.rank = index + 1
                return ranked
            }
            return Self(
                id: key,
                sourceName: source.displayName,
                performance: performance,
                samples: samples,
                sessions: evidence,
                cacheSampleCount: samples.filter { ($0.inputTokens ?? 0) > 0 && $0.cachedInputTokens != nil }.count,
                historyScanIsPartial: source.snapshot.historyScanIsPartial)
        }.sorted { lhs, rhs in
            if lhs.performance.sampleCount != rhs.performance.sampleCount {
                return lhs.performance.sampleCount > rhs.performance.sampleCount
            }
            if lhs.id.sourceID != rhs.id.sourceID { return lhs.id.sourceID < rhs.id.sourceID }
            if lhs.id.model != rhs.id.model { return (lhs.id.model ?? "") < (rhs.id.model ?? "") }
            return (lhs.id.reasoningEffort ?? "") < (rhs.id.reasoningEffort ?? "")
        }
    }
}
