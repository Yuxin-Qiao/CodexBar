import CodexBarCore

/// Context diagnostics using Magpie's four weights. Missing observations never earn points.
struct SpendHarnessRating: Equatable, Sendable {
    enum Dimension: CaseIterable, Sendable {
        case cache, leanStart, growth, reliability

        var maximumPoints: Int {
            switch self {
            case .cache: 35
            case .leanStart: 25
            case .growth, .reliability: 20
            }
        }

        var title: String {
            switch self {
            case .cache: L("spend_harness_cache")
            case .leanStart: L("spend_harness_start")
            case .growth: L("spend_harness_growth")
            case .reliability: L("spend_harness_reliability")
            }
        }
    }

    struct Item: Equatable, Sendable {
        let dimension: Dimension
        let points: Int?
    }

    static let minimumCacheSamples = 5
    static let ruleVersion = "context-diagnostics-v2"
    let items: [Item]

    init(performance: CostUsageTurnPerformanceSummary, cacheSampleCount: Int) {
        let cachePoints: Int? = if cacheSampleCount >= Self.minimumCacheSamples,
                                   cacheSampleCount <= performance.sampleCount,
                                   let fraction = performance.details.cachedInputFraction, fraction.isFinite,
                                   (0...1).contains(fraction)
        {
            Int((min(fraction / 0.9, 1) * Double(Dimension.cache.maximumPoints)).rounded())
        } else {
            nil
        }
        self.items = Dimension.allCases.map {
            Item(dimension: $0, points: $0 == .cache ? cachePoints : nil)
        }
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
}
