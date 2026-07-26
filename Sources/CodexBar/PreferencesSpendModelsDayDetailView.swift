import CodexBarCore
import SwiftUI

// MARK: - Token category colors

extension Color {
    /// Token-category colors for the spend-models day detail panel, tokens.ci style.
    static let spendModelsInput = Color(red: 0.29, green: 0.56, blue: 0.95) // blue
    static let spendModelsOutput = Color(red: 0.20, green: 0.72, blue: 0.51) // green
    static let spendModelsCacheRead = Color(red: 0.61, green: 0.47, blue: 0.90) // purple
    static let spendModelsCacheWrite = Color(red: 0.93, green: 0.58, blue: 0.25) // orange
    static let spendModelsReasoning = Color(red: 0.90, green: 0.42, blue: 0.60) // pink
}

// MARK: - Day detail presentation

struct SpendModelsDayDetailPresentation: Equatable {
    enum BucketKind: String, CaseIterable {
        case input
        case output
        case cacheRead
        case cacheWrite
        case reasoning

        var title: String {
            switch self {
            case .input: L("Input")
            case .output: L("Output")
            case .cacheRead: L("Cache read")
            case .cacheWrite: L("Cache write")
            case .reasoning: L("Reasoning")
            }
        }

        var color: Color {
            switch self {
            case .input: .spendModelsInput
            case .output: .spendModelsOutput
            case .cacheRead: .spendModelsCacheRead
            case .cacheWrite: .spendModelsCacheWrite
            case .reasoning: .spendModelsReasoning
            }
        }
    }

    struct Bucket: Identifiable, Equatable {
        let kind: BucketKind
        let tokens: Int

        var id: String {
            self.kind.rawValue
        }
    }

    struct Model: Identifiable, Equatable {
        let id: String
        let name: String
        let providerNames: [String]
        let totalTokens: Int?
        let cost: Double?
        let costIsEstimated: Bool
        let buckets: [Bucket]
    }

    let day: Date
    let metric: SpendModelMetric
    let totalTokens: Int?
    let totalCost: Double?
    /// Non-zero bucket totals across all models that day; empty when no bucket data exists.
    let buckets: [Bucket]
    /// Per-model rows sorted by tokens descending.
    let models: [Model]

    init?(
        analysis: SpendDashboardModel.ModelAnalysis,
        day: Date,
        metric: SpendModelMetric,
        calendar: Calendar = .current)
    {
        let dailyValues = analysis.dailyValues.filter { calendar.isDate($0.day, inSameDayAs: day) }
        guard !dailyValues.isEmpty else { return nil }

        self.day = day
        self.metric = metric
        self.totalTokens = Self.sum(dailyValues.map(\.totalTokens))
        self.totalCost = Self.sum(dailyValues.map(\.estimatedCost))
        self.buckets = Self.aggregateBuckets(dailyValues.map(Self.buckets(of:)))

        let rowsByID = Dictionary(uniqueKeysWithValues: analysis.rows.map { ($0.id, $0) })
        self.models = dailyValues.map { value in
            let row = rowsByID[value.modelID]
            return Model(
                id: value.modelID,
                name: value.modelName,
                providerNames: row?.providerNames ?? [],
                totalTokens: value.totalTokens,
                cost: value.estimatedCost,
                costIsEstimated: row?.costIsEstimated ?? false,
                buckets: Self.aggregateBuckets([Self.buckets(of: value)]))
        }
        .sorted { lhs, rhs in
            switch (lhs.totalTokens, rhs.totalTokens) {
            case let (left?, right?) where left != right: left > right
            case (_?, nil): true
            case (nil, _?): false
            default: lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private static func buckets(
        of value: SpendDashboardModel.ModelDailyValue) -> [(kind: BucketKind, tokens: Int)]
    {
        [
            (.input, value.inputTokens),
            (.output, value.outputTokens),
            (.cacheRead, value.cacheReadTokens),
            (.cacheWrite, value.cacheCreationTokens),
            (.reasoning, value.reasoningTokens),
        ].compactMap { kind, tokens in
            tokens.map { (kind, $0) }
        }
    }

    /// Sums buckets across models. A bucket with only nil (unknown) values stays hidden, as do
    /// zero totals.
    private static func aggregateBuckets(_ bucketLists: [[(kind: BucketKind, tokens: Int)]]) -> [Bucket] {
        var sums: [BucketKind: Int] = [:]
        for list in bucketLists {
            for (kind, tokens) in list {
                sums[kind, default: 0] += tokens
            }
        }
        return BucketKind.allCases.compactMap { kind in
            guard let total = sums[kind], total > 0 else { return nil }
            return Bucket(kind: kind, tokens: total)
        }
    }

    private static func sum(_ values: [Int?]) -> Int? {
        let present = values.compactMap(\.self)
        guard !present.isEmpty else { return nil }
        return present.reduce(0, +)
    }

    private static func sum(_ values: [Double?]) -> Double? {
        let present = values.compactMap(\.self)
        guard !present.isEmpty else { return nil }
        return present.reduce(0, +)
    }
}

// MARK: - Day detail text helpers

func spendModelsDayDetailBucketText(_ bucket: SpendModelsDayDetailPresentation.Bucket) -> String {
    let count = UsageFormatter.tokenCountString(bucket.tokens)
    switch bucket.kind {
    case .input: return L("%@ in", count)
    case .output: return L("%@ out", count)
    case .cacheRead: return L("%@ cache read", count)
    case .cacheWrite: return L("%@ cache write", count)
    case .reasoning: return L("%@ reasoning", count)
    }
}

/// Compact per-model token split ("80 in · 20 out · 15 cache read"); falls back to the bare
/// total when no bucket data exists.
func spendModelsDayDetailModelSplitText(_ model: SpendModelsDayDetailPresentation.Model) -> String {
    guard !model.buckets.isEmpty else {
        return model.totalTokens.map(UsageFormatter.tokenCountString) ?? "—"
    }
    return model.buckets.map(spendModelsDayDetailBucketText).joined(separator: " · ")
}

// MARK: - Day detail view

struct SpendModelsDayDetailView: View {
    let detail: SpendModelsDayDetailPresentation
    let metric: SpendModelMetric
    let colorForModel: (String) -> Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(self.dayText)
                    .font(.body.weight(.semibold))
                Spacer()
                Text(self.totalText)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
            }
            if !self.detail.buckets.isEmpty {
                self.categoryBar
                self.legend
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(self.detail.models) { model in
                    self.modelRow(model)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L("Usage details for %@", self.dayText)))
    }

    // MARK: Category bar

    /// Thin rounded segmented bar. Reasoning is a subset of output, so the output segment is
    /// shrunk by the reasoning share to keep the bar partitioning the day total.
    private var categoryBar: some View {
        GeometryReader { geo in
            let total = max(1, self.barTokenTotal)
            HStack(spacing: 1) {
                ForEach(self.detail.buckets) { bucket in
                    Rectangle()
                        .fill(bucket.kind.color)
                        .frame(width: max(2, geo.size.width * CGFloat(self.barTokens(for: bucket)) / CGFloat(total)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(self.detail.buckets) { bucket in
                HStack(spacing: 5) {
                    Circle()
                        .fill(bucket.kind.color)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text("\(bucket.kind.title) \(UsageFormatter.tokenCountString(bucket.tokens))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
        }
    }

    private var barTokenTotal: Int {
        self.detail.buckets.reduce(0) { $0 + self.barTokens(for: $1) }
    }

    private func barTokens(for bucket: SpendModelsDayDetailPresentation.Bucket) -> Int {
        guard bucket.kind == .output,
              let reasoning = self.detail.buckets.first(where: { $0.kind == .reasoning })?.tokens
        else {
            return bucket.tokens
        }
        return max(0, bucket.tokens - reasoning)
    }

    // MARK: Model rows

    private func modelRow(_ model: SpendModelsDayDetailPresentation.Model) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(self.colorForModel(model.id))
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(model.name)
                .font(.body)
                .lineLimit(1)
            if !model.providerNames.isEmpty {
                Text(model.providerNames.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Text(spendModelsDayDetailModelSplitText(model))
                .font(.body)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if self.metric == .estimatedSpend {
                Text(self.costText(for: model))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func costText(for model: SpendModelsDayDetailPresentation.Model) -> String {
        guard let cost = model.cost else { return "—" }
        let formatted = UsageFormatter.currencyString(cost, currencyCode: "USD")
        return model.costIsEstimated ? "\(formatted) · \(L("estimated"))" : formatted
    }

    // MARK: Header

    private var dayText: String {
        SpendModelsEnglishFormatter.dayText(self.detail.day)
    }

    private var totalText: String {
        switch self.metric {
        case .tokens: self.detail.totalTokens.map(UsageFormatter.tokenCountString) ?? "—"
        case .estimatedSpend: self.detail.totalCost.map {
                UsageFormatter.currencyString($0, currencyCode: "USD")
            } ?? "—"
        }
    }
}
