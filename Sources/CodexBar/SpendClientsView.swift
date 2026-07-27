import CodexBarCore
import SwiftUI

// MARK: - 按工具分组数据

/// A model's usage attributed to one tool (client), with the five-bucket token breakdown
/// taken from the parent model row (buckets are tracked per model, so the per-client split
/// shares them proportionally by that client's token contribution).
struct SpendClientModel: Identifiable, Equatable {
    let id: String
    let displayName: String
    let tokens: Int
    let cost: Double?
    let costIsEstimated: Bool
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let cacheCreationTokens: Int?
    let reasoningTokens: Int?
}

/// One tool (client) with its models, sorted by tokens descending.
struct SpendClientGroup: Identifiable, Equatable {
    let sourceID: String
    let provider: UsageProvider
    /// Tool name, e.g. "Claude Code", "Codex Desktop", "Kimi Code CLI".
    let toolName: String
    /// Product family name, e.g. "Claude", "Codex", "Kimi".
    let providerName: String
    let totalTokens: Int
    let totalCost: Double?
    let costIsEstimated: Bool
    let models: [SpendClientModel]

    var id: String {
        self.sourceID
    }

    /// "Tool · Family" when they differ meaningfully, else just the tool name.
    var displayTitle: String {
        let tool = self.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let family = self.providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if family.isEmpty || tool.localizedCaseInsensitiveContains(family) {
            return tool
        }
        return "\(tool) · \(family)"
    }
}

enum SpendClientBreakdown {
    /// The local tool that produced a provider's usage logs. Providers whose data is read from a
    /// CLI/desktop app's local files surface under that tool's name; providers with a more specific
    /// `sourceName` (e.g. a Codex account name, or the explicit "… CLI" names set at load time)
    /// keep it untouched.
    private static func toolName(provider: UsageProvider, sourceName: String, providerName: String) -> String {
        // Only remap when the source name is just the product family (no specific tool identity).
        guard sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(providerName.trimmingCharacters(in: .whitespacesAndNewlines))
            == .orderedSame
        else { return sourceName }
        switch provider {
        case .claude: return "Claude Code"
        case .codex: return "Codex Desktop"
        case .kimi: return "Kimi Desktop"
        case .gemini: return "Gemini CLI"
        case .opencode, .opencodego: return "OpenCode"
        case .minimax: return "MiniMax Code"
        case .cursor: return "Cursor"
        case .copilot: return "GitHub Copilot"
        case .antigravity: return "Antigravity"
        default: return sourceName
        }
    }

    /// Groups model rows by contributing tool (one card per tool/account, e.g. each Codex
    /// account, Claude Code, Kimi Code CLI). A model used by several tools appears under each,
    /// with that tool's token/cost share (from `contributions`); the five-bucket breakdown is the
    /// model's own, shown for context under each tool it ran in.
    static func groups(from analysis: SpendDashboardModel.ModelAnalysis) -> [SpendClientGroup] {
        var bySource: [String: (provider: UsageProvider, tool: String, family: String, models: [String: Accum])] = [:]

        for row in analysis.rows {
            for contribution in row.contributions {
                let tokens = contribution.totalTokens ?? 0
                guard tokens > 0 || contribution.estimatedCost != nil else { continue }
                var bucket = bySource[contribution.sourceID]
                    ?? (
                        contribution.provider,
                        Self.toolName(
                            provider: contribution.provider,
                            sourceName: contribution.sourceName,
                            providerName: contribution.providerName),
                        contribution.providerName,
                        [:])
                var accum = bucket.models[row.id] ?? Accum(
                    displayName: row.displayName,
                    costIsEstimated: row.costIsEstimated)
                accum.tokens += tokens
                if let cost = contribution.estimatedCost {
                    accum.cost = (accum.cost ?? 0) + cost
                }
                accum.inputTokens = row.inputTokens
                accum.outputTokens = row.outputTokens
                accum.cacheReadTokens = row.cacheReadTokens
                accum.cacheCreationTokens = row.cacheCreationTokens
                accum.reasoningTokens = row.reasoningTokens
                bucket.models[row.id] = accum
                bySource[contribution.sourceID] = bucket
            }
        }

        return bySource.map { sourceID, bucket in
            let models = bucket.models.map { id, accum in
                SpendClientModel(
                    id: id,
                    displayName: accum.displayName,
                    tokens: accum.tokens,
                    cost: accum.cost,
                    costIsEstimated: accum.costIsEstimated,
                    inputTokens: accum.inputTokens,
                    outputTokens: accum.outputTokens,
                    cacheReadTokens: accum.cacheReadTokens,
                    cacheCreationTokens: accum.cacheCreationTokens,
                    reasoningTokens: accum.reasoningTokens)
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
                toolName: bucket.tool,
                providerName: bucket.family,
                totalTokens: totalTokens,
                totalCost: totalCost,
                costIsEstimated: models.contains { $0.costIsEstimated },
                models: models)
        }
        .sorted { $0.totalTokens > $1.totalTokens }
    }

    private struct Accum {
        let displayName: String
        var tokens = 0
        var cost: Double?
        var costIsEstimated: Bool
        var inputTokens: Int?
        var outputTokens: Int?
        var cacheReadTokens: Int?
        var cacheCreationTokens: Int?
        var reasoningTokens: Int?
    }
}

// MARK: - 按工具分组视图

struct SpendClientsView: View {
    let analysis: SpendDashboardModel.ModelAnalysis

    var body: some View {
        let groups = SpendClientBreakdown.groups(from: self.analysis)
        if groups.isEmpty {
            Text(L("No per-client model history"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(groups) { group in
                    self.card(group)
                }
            }
        }
    }

    private func card(_ group: SpendClientGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let icon = ProviderBrandIcon.image(for: group.provider) {
                    Image(nsImage: icon).resizable().scaledToFit()
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                }
                Text(group.displayTitle)
                    .font(.body.weight(.semibold))
                if group.costIsEstimated {
                    Text(L("Estimated"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                Spacer()
                Text(self.totalText(group))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.bottom, 8)

            ForEach(Array(group.models.enumerated()), id: \.element.id) { index, model in
                if index > 0 { Divider().padding(.vertical, 2) }
                self.modelRow(model, groupTokens: group.totalTokens)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func modelRow(_ model: SpendClientModel, groupTokens: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.displayName)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                Text(self.modelMetric(model))
                    .font(.body)
                    .monospacedDigit()
            }
            if let meta = self.metaText(model) {
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
            }
            if groupTokens > 0 {
                GeometryReader { geo in
                    let share = CGFloat(model.tokens) / CGFloat(groupTokens)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: max(geo.size.width * share, 2), height: 3)
                }
                .frame(height: 3)
            }
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
        if let cost = model.cost {
            return UsageFormatter.currencyString(cost, currencyCode: "USD")
        }
        return UsageFormatter.tokenCountString(model.tokens)
    }

    private func metaText(_ model: SpendClientModel) -> String? {
        var parts: [String] = []
        if let input = model.inputTokens, input > 0 {
            parts.append("Input \(UsageFormatter.tokenCountString(input))")
        }
        if let output = model.outputTokens, output > 0 {
            parts.append("Output \(UsageFormatter.tokenCountString(output))")
        }
        if let cacheRead = model.cacheReadTokens, cacheRead > 0 {
            parts.append("Cache read \(UsageFormatter.tokenCountString(cacheRead))")
        }
        if let cacheWrite = model.cacheCreationTokens, cacheWrite > 0 {
            parts.append("Cache write \(UsageFormatter.tokenCountString(cacheWrite))")
        }
        if let reasoning = model.reasoningTokens, reasoning > 0 {
            parts.append("Reasoning \(UsageFormatter.tokenCountString(reasoning))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
