import CodexBarCore
import SwiftUI

// MARK: - Helper

private func cleanToolName(_ name: String) -> String {
    var result = name
    let suffixes = [" Desktop", " CLI", " IDE", " Extension", " API"]
    for suffix in suffixes where result.hasSuffix(suffix) {
        result = String(result.dropLast(suffix.count))
    }
    return result
}

// MARK: - 按工具分组数据

/// A model's usage attributed to one tool (client).
struct SpendClientModel: Identifiable, Equatable {
    let id: String
    let displayName: String
    let modelProvider: UsageProvider
    let tokens: Int
    let cost: Double?
    let costIsEstimated: Bool
    let requestCount: Int?
}

/// One tool (client) with its models, sorted by tokens descending.
struct SpendClientGroup: Identifiable, Equatable {
    let sourceID: String
    let provider: UsageProvider
    let kind: SpendToolIdentity.Kind
    /// Tool name, e.g. "Claude Code", "Codex Desktop", "Kimi Code CLI".
    let toolName: String
    /// Product family name, e.g. "Claude", "Codex", "Kimi".
    let providerName: String
    let totalTokens: Int
    let totalCost: Double?
    let costIsEstimated: Bool
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let cacheCreationTokens: Int?
    let reasoningTokens: Int?
    let requestCount: Int?
    let coveredDayCount: Int
    let projectCount: Int?
    let sessionCount: Int?
    let models: [SpendClientModel]

    var id: String {
        self.sourceID
    }

    var displayTitle: String {
        self.toolName
    }
}

enum SpendClientBreakdown {
    /// Groups model rows by contributing tool (one card per tool/account, e.g. each Codex
    /// account, Claude Code, Kimi Code CLI). A model used by several tools appears under each,
    /// with that tool's token/cost share (from `contributions`); the five-bucket breakdown is the
    /// model's own, shown for context under each tool it ran in.
    static func groups(from analysis: SpendDashboardModel.ModelAnalysis) -> [SpendClientGroup] {
        var bySource:
            [String: (provider: UsageProvider, identity: SpendToolIdentity, family: String, models: [String: Accum])] =
            [:]

        for row in analysis.rows {
            for contribution in row.contributions {
                let tokens = contribution.totalTokens ?? 0
                guard tokens > 0 || contribution.estimatedCost != nil else { continue }
                var bucket = bySource[contribution.sourceID]
                    ?? (
                        contribution.provider,
                        SpendToolIdentity.resolve(
                            provider: contribution.provider,
                            sourceName: contribution.sourceName,
                            providerName: contribution.providerName),
                        contribution.providerName,
                        [:])
                var accum = bucket.models[row.id] ?? Accum(
                    displayName: row.displayName,
                    modelProvider: row.modelProvider,
                    costIsEstimated: row.costIsEstimated)
                accum.tokens += tokens
                if let cost = contribution.estimatedCost {
                    accum.cost = (accum.cost ?? 0) + cost
                }
                accum.inputTokens = contribution.inputTokens
                accum.outputTokens = contribution.outputTokens
                accum.cacheReadTokens = contribution.cacheReadTokens
                accum.cacheCreationTokens = contribution.cacheCreationTokens
                accum.reasoningTokens = contribution.reasoningTokens
                accum.requestCount = contribution.requestCount
                accum.coveredDayCount = contribution.coveredDayCount
                accum.projectCount = contribution.projectCount
                accum.sessionCount = contribution.sessionCount
                bucket.models[row.id] = accum
                bySource[contribution.sourceID] = bucket
            }
        }

        return bySource.map { sourceID, bucket in
            let models = bucket.models.map { id, accum in
                SpendClientModel(
                    id: id,
                    displayName: accum.displayName,
                    modelProvider: accum.modelProvider,
                    tokens: accum.tokens,
                    cost: accum.cost,
                    costIsEstimated: accum.costIsEstimated,
                    requestCount: accum.requestCount)
            }
            .sorted { $0.tokens > $1.tokens }
            let totalTokens = models.reduce(0) { $0 + $1.tokens }
            let totalCost = models.reduce(nil as Double?) { partial, model in
                guard let cost = model.cost else { return partial }
                return (partial ?? 0) + cost
            }
            return SpendClientGroup(
                sourceID: sourceID,
                provider: bucket.provider,
                kind: bucket.identity.kind,
                toolName: bucket.identity.displayName,
                providerName: bucket.family,
                totalTokens: totalTokens,
                totalCost: totalCost,
                costIsEstimated: models.contains { $0.costIsEstimated },
                inputTokens: Self.completeSum(bucket.models.values.map(\.inputTokens)),
                outputTokens: Self.completeSum(bucket.models.values.map(\.outputTokens)),
                cacheReadTokens: Self.completeSum(bucket.models.values.map(\.cacheReadTokens)),
                cacheCreationTokens: Self.completeSum(bucket.models.values.map(\.cacheCreationTokens)),
                reasoningTokens: Self.completeSum(bucket.models.values.map(\.reasoningTokens)),
                requestCount: Self.completeSum(bucket.models.values.map(\.requestCount)),
                coveredDayCount: bucket.models.values.map(\.coveredDayCount).max() ?? 0,
                projectCount: bucket.models.values.compactMap(\.projectCount).max(),
                sessionCount: bucket.models.values.compactMap(\.sessionCount).max(),
                models: models)
        }
        .sorted { $0.totalTokens > $1.totalTokens }
    }

    private struct Accum {
        let displayName: String
        let modelProvider: UsageProvider
        var tokens = 0
        var cost: Double?
        var costIsEstimated: Bool
        var inputTokens: Int?
        var outputTokens: Int?
        var cacheReadTokens: Int?
        var cacheCreationTokens: Int?
        var reasoningTokens: Int?
        var requestCount: Int?
        var coveredDayCount = 0
        var projectCount: Int?
        var sessionCount: Int?
    }

    private static func completeSum(_ values: [Int?]) -> Int? {
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        return values.compactMap(\.self).reduce(0, +)
    }
}

struct SpendToolModelComparison: Identifiable, Equatable {
    struct Tool: Identifiable, Equatable {
        let sourceID: String
        let provider: UsageProvider
        let displayName: String
        let kind: SpendToolIdentity.Kind
        let contextReuseRate: Double?
        let requestCount: Int?
        let costPerMillionTokens: Double?
        let totalTokens: Int?
        let coveredDayCount: Int

        var id: String {
            self.sourceID
        }
    }

    let id: String
    let displayName: String
    let modelProvider: UsageProvider
    let tools: [Tool]
    let totalTokens: Int
}

enum SpendToolComparisonPresentation {
    static func comparisons(from analysis: SpendDashboardModel.ModelAnalysis) -> [SpendToolModelComparison] {
        analysis.rows.compactMap { row in
            let tools = row.contributions.map { contribution in
                let identity = SpendToolIdentity.resolve(
                    provider: contribution.provider,
                    sourceName: contribution.sourceName,
                    providerName: contribution.providerName)
                return SpendToolModelComparison.Tool(
                    sourceID: contribution.sourceID,
                    provider: contribution.provider,
                    displayName: identity.displayName,
                    kind: identity.kind,
                    contextReuseRate: self.contextReuseRate(
                        input: contribution.inputTokens,
                        cacheRead: contribution.cacheReadTokens,
                        cacheCreation: contribution.cacheCreationTokens),
                    requestCount: contribution.requestCount,
                    costPerMillionTokens: self.costPerMillionTokens(
                        cost: contribution.estimatedCost,
                        tokens: contribution.totalTokens),
                    totalTokens: contribution.totalTokens,
                    coveredDayCount: contribution.coveredDayCount)
            }
            .sorted(by: self.toolOrder)
            guard Set(tools.map(\.sourceID)).count > 1 else { return nil }
            return SpendToolModelComparison(
                id: row.id,
                displayName: row.displayName,
                modelProvider: row.modelProvider,
                tools: tools,
                totalTokens: tools.compactMap(\.totalTokens).reduce(0, +))
        }
        .sorted {
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    static func contextReuseRate(input: Int?, cacheRead: Int?, cacheCreation: Int?) -> Double? {
        guard let input, let cacheRead, let cacheCreation,
              input >= 0, cacheRead >= 0, cacheCreation >= 0
        else {
            return nil
        }
        let denominator = Double(input) + Double(cacheRead) + Double(cacheCreation)
        guard denominator.isFinite, denominator > 0 else { return nil }
        return Double(cacheRead) / denominator
    }

    static func costPerMillionTokens(cost: Double?, tokens: Int?) -> Double? {
        guard let cost, cost.isFinite, cost >= 0, let tokens, tokens > 0 else { return nil }
        return cost * 1_000_000 / Double(tokens)
    }

    private static func toolOrder(
        _ lhs: SpendToolModelComparison.Tool,
        _ rhs: SpendToolModelComparison.Tool) -> Bool
    {
        switch (lhs.contextReuseRate, rhs.contextReuseRate) {
        case let (left?, right?) where left != right: return left > right
        case (_?, nil): return true
        case (nil, _?): return false
        default:
            let left = lhs.totalTokens ?? -1
            let right = rhs.totalTokens ?? -1
            if left != right { return left > right }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }
}

// MARK: - 按工具分组视图

struct SpendClientsView: View {
    let analysis: SpendDashboardModel.ModelAnalysis
    @State private var expandedGroupIDs: Set<String> = []
    @State private var selectedComparisonID: String?

    private static let collapsedModelLimit = 5

    var body: some View {
        let groups = SpendClientBreakdown.groups(from: self.analysis)
        let comparisons = SpendToolComparisonPresentation.comparisons(from: self.analysis)
        if groups.isEmpty {
            Text(L("No per-client model history"))
                .font(SpendModelsListStyle.secondaryFont)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if !comparisons.isEmpty {
                    self.comparisonCard(comparisons)
                }
                ForEach(groups) { group in
                    self.card(group)
                }
            }
        }
    }

    private func comparisonCard(_ comparisons: [SpendToolModelComparison]) -> some View {
        let selected = comparisons.first { $0.id == self.selectedComparisonID } ?? comparisons[0]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L("Same-model comparison"))
                    .font(SpendModelsListStyle.primaryEmphasizedFont)
                Spacer()
                Menu {
                    ForEach(comparisons) { comparison in
                        Button {
                            self.selectedComparisonID = comparison.id
                        } label: {
                            Label(
                                comparison.displayName,
                                systemImage: comparison.id == selected.id ? "checkmark" : "")
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        SpendProviderIcon(
                            provider: selected.modelProvider,
                            size: SpendModelsListStyle.modelIconSize)
                        Text(selected.displayName)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(SpendModelsListStyle.primaryFont)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Text(L("Observed history for the same model and time range; workload differences still apply."))
                .font(SpendModelsListStyle.tertiaryFont)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(selected.tools.enumerated()), id: \.element.id) { index, tool in
                    if index > 0 { Divider().padding(.leading, SpendModelsListStyle.modelIndent) }
                    self.comparisonRow(tool)
                }
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func comparisonRow(_ tool: SpendToolModelComparison.Tool) -> some View {
        HStack(spacing: 8) {
            SpendProviderIcon(provider: tool.provider, size: SpendModelsListStyle.modelIconSize)
                .frame(
                    width: SpendModelsListStyle.modelIconFrameSize,
                    height: SpendModelsListStyle.modelIconFrameSize)
            Text(cleanToolName(tool.displayName))
                .font(SpendModelsListStyle.primaryFont)
                .lineLimit(1)
            Text(tool.kind.displayName)
                .font(SpendModelsListStyle.tertiaryFont.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(self.comparisonMetrics(tool))
                .font(SpendModelsListStyle.secondaryFont)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.vertical, 5)
    }

    private func card(_ group: SpendClientGroup) -> some View {
        let isExpanded = self.expandedGroupIDs.contains(group.id)
        let visibleModels = isExpanded
            ? group.models
            : Array(group.models.prefix(Self.collapsedModelLimit))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                SpendProviderIcon(
                    provider: group.provider,
                    size: SpendModelsListStyle.iconSize)
                    .frame(
                        width: SpendModelsListStyle.iconFrameSize,
                        height: SpendModelsListStyle.iconFrameSize)
                Text(cleanToolName(group.displayTitle))
                    .font(SpendModelsListStyle.primaryEmphasizedFont)
                Text(group.kind.displayName)
                    .font(SpendModelsListStyle.tertiaryFont.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                if group.costIsEstimated {
                    Text(L("Estimated"))
                        .font(SpendModelsListStyle.tertiaryFont)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                Spacer()
                Text(self.totalText(group))
                    .font(SpendModelsListStyle.primaryFont)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.bottom, 6)

            Text(self.toolEvidenceSummary(group))
                .font(SpendModelsListStyle.secondaryFont)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(2)
                .padding(.bottom, 8)
                .padding(.leading, SpendModelsListStyle.iconFrameSize + 7)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visibleModels.enumerated()), id: \.element.id) { index, model in
                    if index > 0 { Divider().padding(.vertical, 2) }
                    self.modelRow(model)
                }
                if group.models.count > Self.collapsedModelLimit {
                    Button {
                        if isExpanded {
                            self.expandedGroupIDs.remove(group.id)
                        } else {
                            self.expandedGroupIDs.insert(group.id)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(isExpanded
                                ? L("Show fewer models")
                                : String(format: L("Show all %d models"), group.models.count))
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.semibold))
                        }
                        .font(SpendModelsListStyle.secondaryFont.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 7)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, SpendModelsListStyle.modelIndent)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func modelRow(_ model: SpendClientModel) -> some View {
        HStack(alignment: .center, spacing: 8) {
            SpendProviderIcon(provider: model.modelProvider, size: SpendModelsListStyle.modelIconSize)
                .frame(
                    width: SpendModelsListStyle.modelIconFrameSize,
                    height: SpendModelsListStyle.modelIconFrameSize)
            Text(model.displayName)
                .font(SpendModelsListStyle.primaryFont)
                .lineLimit(1)
            Spacer()
            Text(self.modelMetric(model))
                .font(SpendModelsListStyle.valueFont)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 5)
    }

    private func totalText(_ group: SpendClientGroup) -> String {
        var parts = [UsageFormatter.tokenCountString(group.totalTokens)]
        if let cost = group.totalCost {
            parts.append(UsageFormatter.currencyString(cost, currencyCode: "USD"))
        }
        return parts.joined(separator: " · ")
    }

    private func modelMetric(_ model: SpendClientModel) -> String {
        var parts = [UsageFormatter.tokenCountString(model.tokens)]
        if let cost = model.cost {
            parts.append(UsageFormatter.currencyString(cost, currencyCode: "USD"))
        }
        return parts.joined(separator: " · ")
    }

    private func toolEvidenceSummary(_ group: SpendClientGroup) -> String {
        var parts = [String(format: L("%d models"), group.models.count)]
        if let requests = group.requestCount {
            parts.append(String(format: L("%@ requests"), UsageFormatter.tokenCountString(requests)))
        }
        if let rate = SpendToolComparisonPresentation.contextReuseRate(
            input: group.inputTokens,
            cacheRead: group.cacheReadTokens,
            cacheCreation: group.cacheCreationTokens)
        {
            parts.append(String(format: L("%d%% context reuse"), Int((rate * 100).rounded())))
        }
        if let projects = group.projectCount {
            parts.append(String(format: L("%d projects"), projects))
        }
        if let sessions = group.sessionCount {
            parts.append(String(format: L("%d sessions"), sessions))
        }
        if group.coveredDayCount > 0 {
            parts.append(String(format: L("%d days covered"), group.coveredDayCount))
        }
        return parts.joined(separator: " · ")
    }

    private func comparisonMetrics(_ tool: SpendToolModelComparison.Tool) -> String {
        var parts: [String] = []
        if let rate = tool.contextReuseRate {
            parts.append(String(format: L("%d%% reuse"), Int((rate * 100).rounded())))
        } else {
            parts.append("\(L("Cache read")) —")
        }
        if let requests = tool.requestCount {
            parts.append(String(format: L("%@ requests"), UsageFormatter.tokenCountString(requests)))
        }
        if let cost = tool.costPerMillionTokens {
            parts.append(String(
                format: L("%@ per 1M tokens"),
                UsageFormatter.currencyString(cost, currencyCode: "USD")))
        }
        if tool.coveredDayCount > 0 {
            parts.append(String(format: L("%d days"), tool.coveredDayCount))
        }
        return parts.joined(separator: " · ")
    }
}
