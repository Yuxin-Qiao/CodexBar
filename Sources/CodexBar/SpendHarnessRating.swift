import CodexBarCore

/// Experimental runtime heuristics for observed turns, not task quality or request reliability.
struct SpendHarnessRating: Equatable, Sendable {
    enum Dimension: CaseIterable, Sendable {
        case cache, response, output, duration

        var maximumPoints: Int {
            switch self {
            case .cache: 35
            case .response: 25
            case .output, .duration: 20
            }
        }

        var title: String {
            switch self {
            case .cache: L("spend_harness_cache")
            case .response: L("spend_harness_response")
            case .output: L("spend_harness_output")
            case .duration: L("spend_harness_duration")
            }
        }
    }

    enum Band: Sendable {
        case good, moderate, poor

        init(points: Int, maximum: Int) {
            let percent = Double(points) / Double(maximum) * 100
            self = percent >= 85 ? .good : percent >= 60 ? .moderate : .poor
        }

        var title: String {
            switch self {
            case .good: L("spend_harness_good")
            case .moderate: L("spend_harness_moderate")
            case .poor: L("spend_harness_poor")
            }
        }
    }

    struct Item: Equatable, Sendable {
        let dimension: Dimension
        let points: Int?

        var description: String? {
            guard let points else { return nil }
            let band = Band(points: points, maximum: self.dimension.maximumPoints)
            let key = switch (self.dimension, band) {
            case (.cache, .good): "spend_harness_reuse_high"
            case (.cache, .moderate): "spend_harness_reuse_moderate"
            case (.cache, .poor): "spend_harness_reuse_low"
            case (.response, .good): "spend_harness_fast"
            case (.response, .moderate): "spend_harness_average"
            case (.response, .poor): "spend_harness_slow"
            case (.output, .good): "spend_harness_output_high"
            case (.output, .moderate): "spend_harness_output_average"
            case (.output, .poor): "spend_harness_output_low"
            case (.duration, .good): "spend_harness_wait_short"
            case (.duration, .moderate): "spend_harness_wait_moderate"
            case (.duration, .poor): "spend_harness_wait_long"
            }
            return L(key)
        }
    }

    static let minimumSamples = 5
    static let ruleVersion = "runtime-experience-v3"
    static let cacheTarget = 0.9
    static let fastResponseSeconds = 1.0
    static let slowResponseSeconds = 10.0
    static let targetOutputTokensPerSecond = 20.0
    static let shortTurnSeconds = 30.0
    static let longTurnSeconds = 300.0
    let items: [Item]

    init(performance: CostUsageTurnPerformanceSummary, cacheSampleCount: Int) {
        let cachePoints: Int? = if cacheSampleCount >= Self.minimumSamples,
                                   cacheSampleCount <= performance.sampleCount,
                                   let fraction = performance.details.cachedInputFraction, fraction.isFinite,
                                   (0...1).contains(fraction)
        {
            Self.points(fraction / Self.cacheTarget, dimension: .cache)
        } else {
            nil
        }
        let hasTimingSamples = performance.sampleCount >= Self.minimumSamples
        let responsePoints = performance.medianFirstTokenMilliseconds.flatMap { milliseconds -> Int? in
            guard performance.firstTokenSampleCount >= Self.minimumSamples else { return nil }
            return Self.points(
                (Self.slowResponseSeconds - milliseconds / 1000) /
                    (Self.slowResponseSeconds - Self.fastResponseSeconds),
                dimension: .response)
        }
        self.items = [
            Item(dimension: .cache, points: cachePoints),
            Item(dimension: .response, points: responsePoints),
            Item(dimension: .output, points: hasTimingSamples ? Self.points(
                performance.outputTokensPerSecond / Self.targetOutputTokensPerSecond,
                dimension: .output) : nil),
            Item(dimension: .duration, points: hasTimingSamples ? Self.points(
                (Self.longTurnSeconds - performance.medianDurationMilliseconds / 1000) /
                    (Self.longTurnSeconds - Self.shortTurnSeconds),
                dimension: .duration) : nil),
        ]
    }

    var cachePoints: Int? {
        self.items.first?.points
    }

    var ratedDimensionCount: Int {
        self.items.filter { $0.points != nil }.count
    }

    var measuredPoints: Int? {
        self.ratedDimensionCount > 0 ? self.items.compactMap(\.points).reduce(0, +) : nil
    }

    var measuredMaximumPoints: Int {
        self.items.filter { $0.points != nil }.reduce(0) { $0 + $1.dimension.maximumPoints }
    }

    var totalPoints: Int? {
        self.ratedDimensionCount == Dimension.allCases.count ? self.measuredPoints : nil
    }

    var totalBand: Band? {
        self.totalPoints.map { Band(points: $0, maximum: 100) }
    }

    private static func points(_ fraction: Double, dimension: Dimension) -> Int? {
        guard fraction.isFinite else { return nil }
        return Int((min(max(fraction, 0), 1) * Double(dimension.maximumPoints)).rounded())
    }
}
