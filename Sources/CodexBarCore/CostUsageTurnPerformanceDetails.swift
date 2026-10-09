import Foundation

/// Observations of completed turns, not a controlled comparison of model generation speed.
public struct CostUsageTurnPerformanceDetails: Sendable, Equatable {
    public let p95DurationMilliseconds: Double?
    public let p95FirstTokenMilliseconds: Double?
    public let outputRateLowerQuartile: Double?
    public let outputRateUpperQuartile: Double?
    public let cachedInputFraction: Double?
    public let cacheSampleCount: Int
    public let groups: [Group]

    public struct Group: Sendable, Equatable {
        public let model: String?
        public let reasoningEffort: String?
        public let sampleCount: Int
        public let firstTokenSampleCount: Int
        public let medianFirstTokenMilliseconds: Double?
        public let medianDurationMilliseconds: Double
        public let outputTokensPerSecond: Double
    }

    private struct Key: Hashable {
        let model: String?
        let effort: String?
    }

    public init(samples: [CostUsageTurnPerformanceSample]) {
        self.init(
            samples: samples,
            sortedDurations: samples.map(\.durationMilliseconds).sorted(),
            sortedFirstTokens: samples.compactMap(\.firstTokenMilliseconds).sorted())
    }

    init(samples: [CostUsageTurnPerformanceSample], sortedDurations: [Int], sortedFirstTokens: [Int]) {
        self.p95DurationMilliseconds = Self.percentile(
            sortedDurations, fraction: 0.95, minimumCount: 20).map(Double.init)
        self.p95FirstTokenMilliseconds = Self.percentile(
            sortedFirstTokens, fraction: 0.95, minimumCount: 20).map(Double.init)
        let rates = samples.map { Double($0.outputTokens) / Double($0.durationMilliseconds) * 1000 }.sorted()
        self.outputRateLowerQuartile = Self.percentile(rates, fraction: 0.25, minimumCount: 4)
        self.outputRateUpperQuartile = Self.percentile(rates, fraction: 0.75, minimumCount: 4)
        let cacheSamples = samples.filter { $0.inputTokens != nil && $0.cachedInputTokens != nil }
        self.cacheSampleCount = cacheSamples.count
        if let input = CheckedSum.integers(cacheSamples.compactMap(\.inputTokens)), input > 0,
           let cached = CheckedSum.integers(cacheSamples.compactMap(\.cachedInputTokens))
        {
            self.cachedInputFraction = Double(cached) / Double(input)
        } else {
            self.cachedInputFraction = nil
        }
        let observationsByKey = Dictionary(grouping: samples) { Key(model: $0.model, effort: $0.reasoningEffort) }
        let hasSingleGroup = observationsByKey.count == 1
        self.groups = observationsByKey
            .compactMap { key, observations in
                guard let output = CheckedSum.integers(observations.map(\.outputTokens)),
                      let duration = CheckedSum.integers(observations.map(\.durationMilliseconds)), duration > 0
                else { return nil }
                let firstTokens = hasSingleGroup
                    ? sortedFirstTokens : observations.compactMap(\.firstTokenMilliseconds).sorted()
                let durations = hasSingleGroup
                    ? sortedDurations : observations.map(\.durationMilliseconds).sorted()
                return Group(
                    model: key.model,
                    reasoningEffort: key.effort,
                    sampleCount: observations.count,
                    firstTokenSampleCount: firstTokens.count,
                    medianFirstTokenMilliseconds: Self.median(firstTokens),
                    medianDurationMilliseconds: Self.median(durations) ?? 0,
                    outputTokensPerSecond: Double(output) / Double(duration) * 1000)
            }.sorted {
                if $0.model != $1.model { return ($0.model ?? "") < ($1.model ?? "") }
                return ($0.reasoningEffort ?? "") < ($1.reasoningEffort ?? "")
            }
    }

    /// Nearest-rank percentiles. P95 requires 20 observations; quartiles require four.
    private static func percentile<T>(_ sorted: [T], fraction: Double, minimumCount: Int) -> T? {
        guard sorted.count >= minimumCount else { return nil }
        return sorted[Int(ceil(Double(sorted.count) * fraction)) - 1]
    }

    private static func median(_ sorted: [Int]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? Double(sorted[middle - 1]) / 2 + Double(sorted[middle]) / 2 : Double(sorted[middle])
    }
}
