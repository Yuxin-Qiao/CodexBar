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
    let tokens: Int?
    let cost: Double?
    let costIsEstimated: Bool
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let cacheCreationTokens: Int?
    let reasoningTokens: Int?
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
    let totalTokens: Int?
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
                let tokens = contribution.totalTokens
                guard (tokens ?? 0) > 0 || contribution.estimatedCost != nil else { continue }
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
                    costIsEstimated: contribution.costIsEstimated)
                accum.tokens = Self.add(accum.tokens, tokens)
                if let cost = contribution.estimatedCost {
                    let nextCost = (accum.cost ?? 0) + cost
                    accum.cost = nextCost.isFinite ? nextCost : nil
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
                    inputTokens: accum.inputTokens,
                    outputTokens: accum.outputTokens,
                    cacheReadTokens: accum.cacheReadTokens,
                    cacheCreationTokens: accum.cacheCreationTokens,
                    reasoningTokens: accum.reasoningTokens,
                    requestCount: accum.requestCount)
            }
            .sorted { ($0.tokens ?? -1) > ($1.tokens ?? -1) }
            let totalTokens = Self.completeSum(models.map(\.tokens))
            let totalCost = Self.completeCostSum(models.map(\.cost))
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
        .sorted { ($0.totalTokens ?? -1) > ($1.totalTokens ?? -1) }
    }

    private struct Accum {
        let displayName: String
        let modelProvider: UsageProvider
        var tokens: Int? = 0
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
        var total = 0
        for value in values.compactMap(\.self) {
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }

    private static func completeCostSum(_ values: [Double?]) -> Double? {
        guard values.allSatisfy({ $0?.isFinite == true }) else { return nil }
        var total = 0.0
        for value in values.compactMap(\.self) {
            total += value
            guard total.isFinite else { return nil }
        }
        return total
    }

    private static func add(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard let lhs, let rhs else { return nil }
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }
}

// MARK: - 模型明细文本

/// Composes the per-model token-bucket detail line shown under each model row.
enum SpendClientModelDetailText {
    static func detailText(model: SpendClientModel) -> String {
        var parts: [String] = []
        if let tokens = model.tokens {
            parts.append(String(format: L("%@ tokens"), UsageFormatter.tokenCountString(tokens)))
        }
        let buckets: [(kind: SpendModelsDayDetailPresentation.BucketKind, tokens: Int?)] = [
            (.input, model.inputTokens),
            (.output, model.outputTokens),
            (.cacheRead, model.cacheReadTokens),
            (.cacheWrite, model.cacheCreationTokens),
            (.reasoning, model.reasoningTokens),
        ]
        for bucket in buckets {
            guard let tokens = bucket.tokens, tokens > 0 else { continue }
            parts.append("\(bucket.kind.title) \(UsageFormatter.tokenCountString(tokens))")
        }
        if let requestCount = model.requestCount, requestCount > 0 {
            parts.append("\(UsageFormatter.tokenCountString(requestCount)) \(L("messages"))")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 模型花费文本

/// Formats the model row's right-side metric: cost, falling back to tokens when unpriced.
enum SpendClientModelMetricText {
    static func text(cost: Double?, tokens: Int?, currencyCode: String) -> String {
        if let cost {
            return UsageFormatter.currencyString(cost, currencyCode: currencyCode)
        }
        if let tokens {
            return UsageFormatter.tokenCountString(tokens)
        }
        return "—"
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
                totalTokens: tools.compactMap(\.totalTokens).reduce(0) { total, value in
                    let result = total.addingReportingOverflow(value)
                    return result.overflow ? Int.max : result.partialValue
                })
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
    let currencyCode: String
    @State private var collapsedGroupIDs: Set<String> = []
    @State private var selectedComparisonID: String?

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
                Text(L("CLIENTS & MODELS"))
                    .font(SpendModelsListStyle.tertiaryFont.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
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
        let isCollapsed = self.collapsedGroupIDs.contains(group.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isCollapsed {
                        self.collapsedGroupIDs.remove(group.id)
                    } else {
                        self.collapsedGroupIDs.insert(group.id)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    SpendProviderIcon(
                        provider: group.provider,
                        size: SpendModelsListStyle.clientIconSize)
                        .frame(
                            width: SpendModelsListStyle.clientIconFrameSize,
                            height: SpendModelsListStyle.clientIconFrameSize)
                    Text(cleanToolName(group.displayTitle))
                        .font(SpendModelsListStyle.toolTitleFont)
                    Spacer()
                    Text(self.totalText(group))
                        .font(SpendModelsListStyle.clientTotalsFont)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, isCollapsed ? 0 : 10)

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(group.models) { model in
                        self.modelRow(model)
                    }
                }
                .padding(.leading, SpendModelsListStyle.clientIconFrameSize + 10)
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func modelRow(_ model: SpendClientModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 8) {
                SpendProviderIcon(provider: model.modelProvider, size: SpendModelsListStyle.modelRowIconSize)
                    .frame(
                        width: SpendModelsListStyle.modelRowIconFrameSize,
                        height: SpendModelsListStyle.modelRowIconFrameSize)
                Text(model.displayName)
                    .font(SpendModelsListStyle.modelNameFont)
                    .lineLimit(1)
                Spacer()
                Text(self.modelMetric(model))
                    .font(SpendModelsListStyle.modelCostFont)
                    .monospacedDigit()
            }

            let detail = SpendClientModelDetailText.detailText(model: model)
            if !detail.isEmpty {
                Text(detail)
                    .font(SpendModelsListStyle.modelDetailFont)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineSpacing(3)
                    .padding(.leading, SpendModelsListStyle.modelRowIconFrameSize + 8)
            }
        }
        .padding(.vertical, 7)
    }

    private func totalText(_ group: SpendClientGroup) -> String {
        var parts: [String] = []
        if let tokens = group.totalTokens {
            parts.append(UsageFormatter.tokenCountString(tokens))
        }
        if let cost = group.totalCost {
            parts.append(UsageFormatter.currencyString(cost, currencyCode: self.currencyCode))
        }
        return parts.joined(separator: " · ")
    }

    private func modelMetric(_ model: SpendClientModel) -> String {
        SpendClientModelMetricText.text(cost: model.cost, tokens: model.tokens, currencyCode: self.currencyCode)
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
                UsageFormatter.currencyString(cost, currencyCode: self.currencyCode)))
        }
        if tool.coveredDayCount > 0 {
            parts.append(String(format: L("%d days"), tool.coveredDayCount))
        }
        return parts.joined(separator: " · ")
    }
}
