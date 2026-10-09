import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct SpendAgentProfileTests {
    private static let now = Date(timeIntervalSince1970: 1_778_414_400)

    private struct RatingExample {
        let sample: CostUsageTurnPerformanceSample
        let points: [Int]
        let band: SpendHarnessRating.Band
    }

    @Test
    func `profiles aggregate raw turns with token weighted cache and time weighted throughput`() throws {
        let small = try Self.sample(input: 10, cached: 0, duration: 1000)
        let large = try Self.sample(input: 990, cached: 990, duration: 9000)
        let input = Self.input(sampleSets: [[small, small, small, small], [large]])
        let group = try Self.group(inputs: [input])
        let profile = try #require(group.agentProfiles.first)
        #expect(profile.performance.sampleCount == 5)
        #expect(profile.performance.medianDurationMilliseconds == 1000)
        #expect(abs(profile.performance.outputTokensPerSecond - 500.0 / 13) < 0.001)
        #expect(profile.cacheScore == 35)
        #expect(profile.sessions.count == 2)
        #expect(profile.sessions.map(\.rank) == [1, 2])
        for _ in 0..<10 {
            #expect(try Self.group(inputs: [input]).agentProfiles == group.agentProfiles)
        }
    }

    @Test
    func `harness totals use raw turns across configurations instead of averaging medians and percentages`() throws {
        let small = try Self.sample(input: 10, cached: 0, duration: 1000)
        let large = try Self.sample(input: 990, cached: 990, duration: 9000, effort: "low")
        let group = try Self.group(inputs: [
            Self.input(id: "a", sampleSets: [[small, small, small, small]]),
            Self.input(id: "b", sampleSets: [[large]]),
        ])
        let harness = try #require(spendDashboardProviderBreakdowns(group).first)
        let performance = try #require(harness.performance)
        #expect(group.agentProfiles.count == 2)
        #expect(performance.sampleCount == 5)
        #expect(performance.medianDurationMilliseconds == 1000)
        #expect(abs(performance.outputTokensPerSecond - 500.0 / 13) < 0.001)
        #expect(try abs(#require(performance.details.cachedInputFraction) - 990.0 / 1030) < 0.001)
        #expect(harness.cacheSampleCount == 5)
    }

    @Test
    func `partial native sources without eligible turns still mark the combined harness history`() throws {
        let measured = try Self.sample(input: 100, cached: 80, firstToken: 200)
        let old = try Self.sample(date: Self.now.addingTimeInterval(-30 * 86400))
        let complete = Self.input(id: "complete", sampleSets: [Array(repeating: measured, count: 5)])
        for missingSamples in [[], [old]] {
            let partial = Self.input(id: "partial", sampleSets: [missingSamples], partial: true)
            for selectedDay in [nil, Self.now] {
                let group = try Self.group(inputs: [complete, partial], selectedDay: selectedDay)
                #expect(group.agentProfiles.count == 1)
                let harness = try #require(spendDashboardProviderBreakdowns(group).first)
                #expect(harness.performance?.sampleCount == 5)
                #expect(harness.historyScanIsPartial)
                let performance = try #require(harness.performance)
                let text = SpendHarnessPerformanceText(
                    performance: performance,
                    cacheSampleCount: harness.cacheSampleCount,
                    historyScanIsPartial: harness.historyScanIsPartial)
                CodexBarLocalizationOverride.$appLanguage.withValue("en") {
                    #expect(text.observationsText.contains("Partial history"))
                }
            }
        }
    }

    @Test
    func `hidden imported and other provider scans cannot mark native harness history partial`() throws {
        let sample = try Self.sample(input: 100, cached: 80, firstToken: 200)
        let complete = Self.input(id: "complete", sampleSets: [Array(repeating: sample, count: 5)])
        let group = try Self.group(inputs: [
            complete,
            Self.input(id: "hidden", sampleSets: [[]], partial: true),
            Self.input(id: "imported", sampleSets: [[]], source: .openCodex, partial: true),
            Self.input(id: "other", sampleSets: [[]], provider: .claude, partial: true),
        ], hiddenSourceIDs: ["hidden"])
        let harness = try #require(spendDashboardProviderBreakdowns(group).first { $0.provider == .codex })
        #expect(harness.performance?.sampleCount == 5)
        #expect(!harness.historyScanIsPartial)
    }

    @Test
    func `spend summaries omit timed history while preserving billing and coverage`() throws {
        let sample = try Self.sample(input: 100, cached: 80, firstToken: 200)
        let input = Self.input(
            sampleSets: Array(repeating: Array(repeating: sample, count: 5), count: 60),
            partial: true,
            includeModelHistory: true)
        let full = try Self.group(inputs: [input])
        let summary = try Self.group(inputs: [input], includeSessionDetails: false)
        #expect(full.agentProfiles.first?.performance.sampleCount == 300)
        #expect(full.sessions.count == SpendDashboardModel.sessionRowLimit)
        #expect(summary.agentProfiles.isEmpty)
        #expect(summary.sessions.isEmpty)
        #expect(summary.providerBreakdowns.first?.performance == nil)
        #expect(summary.providers == full.providers)
        #expect(summary.models == full.models)
        #expect(summary.projects == full.projects)
        #expect(summary.dailyPoints == full.dailyPoints)
        #expect(summary.dailySummaries == full.dailySummaries)
        #expect(summary.totalTokens == full.totalTokens)
        #expect(summary.totalCost == full.totalCost)
        #expect(summary.coverage == full.coverage)
        #expect(summary.tokenMix == full.tokenMix)
        #expect(summary.modelHistoryCompleteness == full.modelHistoryCompleteness)
    }

    @Test
    func `missing cache and zero input stay unknown while measured zero reuse scores zero`() throws {
        let missing = try Self.sample()
        let zeroInput = try Self.sample(input: 0, cached: 0)
        let noReuse = try Self.sample(input: 100, cached: 0)
        let invalid = try Self.sample(input: 100, cached: 101)
        for sample in [missing, zeroInput, invalid] {
            let group = try Self.group(inputs: [Self.input(sampleSets: [Array(repeating: sample, count: 8)])])
            let profile = try #require(group.agentProfiles.first)
            #expect(profile.cacheScore == nil)
            #expect(profile.cacheSampleCount == 0)
            #expect(profile.performance.details.cachedInputFraction == nil)
        }
        let zeroGroup = try Self.group(inputs: [Self.input(sampleSets: [Array(repeating: noReuse, count: 5)])])
        #expect(zeroGroup.agentProfiles.first?.cacheScore == 0)
        let observingGroup = try Self.group(inputs: [Self.input(sampleSets: [Array(repeating: noReuse, count: 4)])])
        #expect(observingGroup.agentProfiles.first?.cacheScore == nil)
        #expect(observingGroup.agentProfiles.first?.performance.details.cachedInputFraction == 0)
    }

    @Test
    func `partial cache and first token coverage remain explicit and integer overflow cannot score`() throws {
        let measured = try Self.sample(input: 100, cached: 80, firstToken: 200)
        let missing = try Self.sample()
        let group = try Self.group(inputs: [Self.input(
            sampleSets: [Array(repeating: measured, count: 5) + Array(repeating: missing, count: 3)],
            partial: true)])
        let profile = try #require(group.agentProfiles.first)
        #expect(profile.cacheScore == 31)
        #expect(profile.cacheSampleCount == 5)
        #expect(profile.performance.sampleCount == 8)
        #expect(profile.performance.firstTokenSampleCount == 5)
        #expect(profile.historyScanIsPartial)
        let overflow = try Self.sample(input: Int.max, cached: Int.max)
        let overflowGroup = try Self.group(inputs: [Self.input(sampleSets: [Array(repeating: overflow, count: 5)])])
        #expect(overflowGroup.agentProfiles.first?.cacheScore == nil)
        #expect(overflowGroup.agentProfiles.first?.performance.details.cachedInputFraction == nil)
    }

    @Test
    func `cache points follow the ninety percent target and missing response keeps the total unscored`() throws {
        for (cached, expected) in [(0, 0), (45, 18), (79, 31), (80, 31), (88, 34), (90, 35), (100, 35)] {
            let sample = try Self.sample(input: 100, cached: cached)
            let performance = try #require(CostUsageTurnPerformanceSummary(samples: Array(repeating: sample, count: 5)))
            let rating = SpendHarnessRating(performance: performance, cacheSampleCount: 5)
            #expect(rating.cachePoints == expected)
            #expect(rating.measuredPoints == expected + 40)
            #expect(rating.measuredMaximumPoints == 75)
            #expect(rating.ratedDimensionCount == 3)
            #expect(rating.totalPoints == nil)
            #expect(rating.items.map(\.dimension.maximumPoints) == [35, 25, 20, 20])
            #expect(rating.items[1].points == nil)
            #expect(rating.items[2].points == 20)
            #expect(rating.items[3].points == 20)
        }
        let sample = try Self.sample(input: 100, cached: 80)
        for count in 1...4 {
            let performance = try #require(CostUsageTurnPerformanceSummary(samples: Array(
                repeating: sample,
                count: count)))
            let rating = SpendHarnessRating(performance: performance, cacheSampleCount: count)
            #expect(rating.measuredPoints == nil)
            #expect(rating.measuredMaximumPoints == 0)
            #expect(rating.ratedDimensionCount == 0)
        }
    }

    @Test
    func `complete experience scores clamp to zero and one hundred with interpretable components`() throws {
        let cases: [RatingExample] = try [
            .init(
                sample: Self.sample(input: 100, cached: 90, duration: 30000, output: 600, firstToken: 1000),
                points: [35, 25, 20, 20],
                band: .good),
            .init(
                sample: Self.sample(input: 100, cached: 100, duration: 1000, output: 1000, firstToken: 0),
                points: [35, 25, 20, 20],
                band: .good),
            .init(
                sample: Self.sample(input: 100, cached: 0, duration: 300_000, output: 1, firstToken: 10000),
                points: [0, 0, 0, 0],
                band: .poor),
            .init(
                sample: Self.sample(input: 100, cached: 45, duration: 165_000, output: 1650, firstToken: 5500),
                points: [18, 13, 10, 10],
                band: .poor),
            .init(
                sample: Self.sample(input: 100, cached: 90, duration: 30000, output: 300, firstToken: 5500),
                points: [35, 13, 10, 20],
                band: .moderate),
        ]
        for example in cases {
            let performance = try #require(CostUsageTurnPerformanceSummary(samples: Array(
                repeating: example.sample,
                count: 5)))
            let rating = SpendHarnessRating(performance: performance, cacheSampleCount: 5)
            #expect(rating.items.compactMap(\.points) == example.points)
            #expect(rating.totalPoints == example.points.reduce(0, +))
            #expect(rating.totalBand == example.band)
            #expect(rating.measuredMaximumPoints == 100)
            #expect(rating.ratedDimensionCount == 4)
        }
    }

    @Test
    func `experience scores need five measured samples for each component without filling missing data`() throws {
        let measured = try Self.sample(input: 100, cached: 80, firstToken: 700)
        let missing = try Self.sample()
        for measuredCount in 0...4 {
            let samples = Array(repeating: measured, count: measuredCount) +
                Array(repeating: missing, count: 5 - measuredCount)
            let performance = try #require(CostUsageTurnPerformanceSummary(samples: samples))
            let rating = SpendHarnessRating(performance: performance, cacheSampleCount: measuredCount)
            #expect(rating.items[0].points == nil)
            #expect(rating.items[1].points == nil)
            #expect(rating.items[2].points == 20)
            #expect(rating.items[3].points == 20)
            #expect(rating.ratedDimensionCount == 2)
            #expect(rating.totalPoints == nil)
            #expect(rating.totalBand == nil)
        }
    }

    @Test
    func `score and four dimension statuses are visible without opening another menu`() throws {
        let measured = try Self.sample(input: 100, cached: 80, firstToken: 200)
        let missing = try Self.sample()
        let performance = try #require(CostUsageTurnPerformanceSummary(samples:
            Array(repeating: measured, count: 5) + Array(repeating: missing, count: 3)))
        let text = SpendHarnessPerformanceText(
            performance: performance,
            cacheSampleCount: 5,
            historyScanIsPartial: true)
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            #expect(text.scoreText == "Runtime reference 96/100 · Experimental")
            #expect(text.dimensionsText == "Cache High reuse · First token Fast · Turn output High · Short turn")
            #expect(text.componentScoresText == "Cache 31/35 (High reuse) · First token 25/25 (Fast) · " +
                "Turn output 20/20 (High) · Turn time 20/20 (Short turn)")
            #expect(text.evidenceText.contains(text.componentScoresText))
            #expect(text.rawMetricsText.contains("80.0%"))
            #expect(text.rawMetricsText.contains("Cache: 5/8 turns"))
            #expect(text.evidenceText.contains(text.rawMetricsText))
            #expect(!text.observationsText.contains("tok/s"))
            #expect(text.observationsText.contains("Partial history"))
            #expect(text.observationsText.contains("Task performance Not evaluated"))
            #expect(text.evidenceText.contains("this does not rate task quality"))
            #expect(text.evidenceText.contains("no task success rate is available"))
        }
        CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            #expect(text.scoreText == "运行参考96分 · 实验性")
            #expect(text.dimensionsText == "缓存 复用好 · 首响 快 · 整轮输出 高 · 耗时短")
            #expect(text.componentScoresText == "缓存 31/35 (复用好) · 首响 25/25 (快) · " +
                "整轮输出 20/20 (高) · 回合耗时 20/20 (耗时短)")
            #expect(text.rawMetricsText.contains("缓存数据：5/8 个回合"))
            #expect(text.observationsText.contains("8轮数据"))
            #expect(text.observationsText.contains("历史记录不完整"))
            #expect(text.observationsText.contains("任务表现 尚未评价"))
        }
    }

    @Test
    func `rating evidence uses actual component coverage and the scoring thresholds`() throws {
        let measured = try Self.sample(input: 100, cached: 80, firstToken: 200)
        let missing = try Self.sample()
        let performance = try #require(CostUsageTurnPerformanceSummary(samples:
            Array(repeating: measured, count: 5) + Array(repeating: missing, count: 3)))
        let evidence = SpendHarnessRatingEvidence(performance: performance, cacheSampleCount: 5)
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            #expect(evidence.observation(.cache) == "80% · Data for 5/8 turns")
            #expect(evidence.observation(.response).contains("5/8"))
            #expect(evidence.observation(.output).contains("8/8"))
            #expect(evidence.observation(.duration).contains("8/8"))
            #expect(evidence.rule(.cache) == "90% cache reuse earns all 35 points; " +
                "lower reuse is scored proportionally.")
            #expect(evidence.rule(.response) == "1 s or less earns all 25 points; 10 s or more earns zero.")
            #expect(evidence.rule(.output) == "20 tok/s or more earns all 20 points; " +
                "lower whole-turn output is scored proportionally.")
            #expect(evidence.rule(.duration) == "30 s or less earns all 20 points; 300 s or more earns zero.")
            #expect(evidence.definition(.response).contains("may be reasoning"))
            #expect(evidence.definition(.output).contains("Total output tokens / total turn time"))
            #expect(evidence.definition(.output).contains("Token counts vary by model"))
            #expect(evidence.definition(.duration).contains("More demanding tasks may take longer"))
        }
        CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            #expect(evidence.observation(.cache) == "80% · 有效数据 5/8 轮")
            #expect(evidence.rule(.response).contains("1 秒"))
            #expect(evidence.rule(.duration).contains("300 秒"))
        }
    }

    @Test
    func `rating evidence distinguishes unavailable data from observations below the threshold`() throws {
        let missing = try Self.sample()
        let measured = try Self.sample(input: 100, cached: 80, firstToken: 200)
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for measuredCount in 0...4 {
                let performance = try #require(CostUsageTurnPerformanceSummary(samples:
                    Array(repeating: measured, count: measuredCount) +
                        Array(repeating: missing, count: 5 - measuredCount)))
                let evidence = SpendHarnessRatingEvidence(performance: performance, cacheSampleCount: measuredCount)
                let rating = SpendHarnessRating(performance: performance, cacheSampleCount: measuredCount)
                #expect(evidence.status(rating.items[0]) == (measuredCount == 0 ? "Unavailable" : "Observing"))
                #expect(evidence.status(rating.items[1]) == (measuredCount == 0 ? "Unavailable" : "Observing"))
                #expect(evidence.observation(.cache).contains("\(measuredCount)/5"))
                #expect(evidence.observation(.response).contains("\(measuredCount)/5"))
                #expect(evidence.status(rating.items[2]) == "High")
                #expect(rating.totalPoints == nil)
                let text = SpendHarnessPerformanceText(
                    performance: performance,
                    cacheSampleCount: measuredCount,
                    historyScanIsPartial: false)
                #expect(text.scoreText == "Runtime pending · 2/4 rated · Experimental")
                #expect(text.observationsText.contains("Not evaluated"))
            }
        }
    }

    @Test
    func `sources model and effort remain distinct and hidden or unsupported providers never contribute`() throws {
        let high = try Self.sample(input: 100, cached: 80)
        let low = try Self.sample(input: 100, cached: 10, effort: "low")
        let otherModel = try Self.sample(model: "gpt-5")
        let unknown = try Self.sample(model: nil, effort: nil)
        let inputs = [
            Self.input(id: "a", sampleSets: [[high, low, otherModel, unknown]]),
            Self.input(id: "b", sampleSets: [[high]]),
            Self.input(id: "claude", sampleSets: [[high]], provider: .claude),
            Self.input(id: "opencodex", sampleSets: [[high]], source: .openCodex),
            Self.input(id: "local", sampleSets: [[high]], source: .localHistory),
        ]
        let group = try Self.group(inputs: inputs)
        #expect(group.agentProfiles.count == 5)
        #expect(Set(group.agentProfiles.map(\.id.sourceID)) == ["a", "b"])
        let breakdowns = spendDashboardProviderBreakdowns(group)
        let codex = try #require(breakdowns.first { $0.provider == .codex })
        #expect(codex.performance?.sampleCount == group.agentProfiles.reduce(0) { $0 + $1.performance.sampleCount })
        #expect(codex.performance?.sampleCount == 5)
        let otherBreakdowns = breakdowns.filter { $0.provider != .codex }
        #expect(otherBreakdowns.allSatisfy { $0.performance == nil && $0.cacheSampleCount == 0 })
        #expect(breakdowns.filter { $0.provider != .codex }.compactMap(\.performance).isEmpty)
        let unknownProfile = try #require(group.agentProfiles.first { $0.id.model == nil })
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            #expect(unknownProfile.modelName == "Unknown model")
            #expect(unknownProfile.effortName == "Unknown reasoning effort")
            #expect(unknownProfile.displaySourceName(hidePersonalInfo: true) == "Codex")
        }
        #expect(unknownProfile.displaySourceName(hidePersonalInfo: false) == "Synthetic source a")
        let hidden = try Self.group(inputs: inputs, hiddenSourceIDs: ["a"])
        #expect(hidden.agentProfiles.count == 1)
        #expect(hidden.agentProfiles.first?.id.sourceID == "b")
        let hiddenCodex = try #require(spendDashboardProviderBreakdowns(hidden).first { $0.provider == .codex })
        #expect(hiddenCodex.subscriptions.contains { $0.id == "b" })
        #expect(!hiddenCodex.subscriptions.contains { $0.id == "a" })
        #expect(hiddenCodex.performance?.sampleCount == hidden.agentProfiles.first?.performance.sampleCount)
    }

    @Test
    func `selected day and reporting window filter completion dates in the reporting timezone`() throws {
        let today = try Self.sample()
        let yesterday = try Self.sample(date: Self.now.addingTimeInterval(-86400))
        let outside = try Self.sample(date: Self.now.addingTimeInterval(-8 * 86400))
        let tomorrow = try Self.sample(date: Self.now.addingTimeInterval(86400))
        let input = Self.input(sampleSets: [[today, yesterday, outside, tomorrow]], lastActivity: tomorrow.completedAt)
        let range = try Self.group(inputs: [input])
        #expect(range.agentProfiles.first?.performance.sampleCount == 2)
        let selected = try Self.group(inputs: [input], selectedDay: yesterday.completedAt)
        #expect(selected.agentProfiles.first?.performance.sampleCount == 1)
        #expect(selected.agentProfiles.first?.sessions.count == 1)
        let empty = try Self.group(inputs: [input], selectedDay: Self.now.addingTimeInterval(-2 * 86400))
        #expect(empty.agentProfiles.isEmpty)
        let beforeMidnight = try Self.sample(date: Self.now.addingTimeInterval(-18 * 3600))
        let zone = try #require(TimeZone(secondsFromGMT: 8 * 3600))
        let zoned = try Self.group(
            inputs: [Self.input(sampleSets: [[beforeMidnight, today]])],
            selectedDay: Self.now,
            timeZone: zone)
        #expect(zoned.agentProfiles.first?.performance.sampleCount == 2)
        let utc = try Self.group(
            inputs: [Self.input(sampleSets: [[beforeMidnight, today]])],
            selectedDay: Self.now)
        #expect(utc.agentProfiles.first?.performance.sampleCount == 1)
    }

    @Test
    func `evidence includes sessions beyond fifty and only matching configuration timing`() throws {
        let high = try Self.sample(input: 100, cached: 80)
        let low = try Self.sample(duration: 9000, effort: "low")
        let input = Self.input(sampleSets: Array(repeating: [high, low], count: 60))
        let group = try Self.group(inputs: [input])
        #expect(group.sessions.count == 50)
        let profile = try #require(group.agentProfiles.first { $0.id.reasoningEffort == "high" })
        #expect(profile.sessions.count == 60)
        #expect(profile.performance.sampleCount == 60)
        #expect(profile.sessions.last?.rank == 60)
        #expect(profile.sessions.allSatisfy { $0.turnPerformance?.sampleCount == 1 })
        #expect(profile.sessions.allSatisfy { $0.turnPerformance?.medianDurationMilliseconds == 1000 })
        #expect(profile.sessions.first?.totalCost == group.sessions.first?.totalCost)
        #expect(profile.sessions.first?.displayIdentity(hidePersonalInfo: true).name != "Synthetic task 59")
        #expect(spendDashboardProviderBreakdowns(group).first?.performance?.sampleCount == 120)
    }

    @Test
    func `render metrics directly after harness names using synthetic history`() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_AGENT_PROFILE_UI_PROOF_DIR"] else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let high = try (0..<20).map { index in
            try Self.sample(
                input: 1000,
                cached: 850 + index % 4 * 20,
                duration: 6000 + index * 150,
                firstToken: 600 + index * 20)
        }
        let medium = try (0..<8).map { index in
            try Self.sample(
                input: 1000,
                cached: 600,
                duration: 3000 + index * 150,
                firstToken: 400,
                effort: "medium")
        }
        let missing = try Self.sample(model: "gpt-5", effort: nil)
        let input = Self.input(
            sampleSets: [Array(high.prefix(10)), Array(high.suffix(10)), medium, [missing, missing]],
            includeModelHistory: true,
            displayName: "Codex")
        let cursor = try Self.input(
            id: "cursor",
            sampleSets: [[Self.sample(model: "example-cursor-model")]],
            provider: .cursor,
            includeModelHistory: true,
            displayName: "Cursor")
        let claude = try Self.input(
            id: "claude",
            sampleSets: [[Self.sample(model: "example-claude-model")]],
            provider: .claude,
            includeModelHistory: true,
            displayName: "Claude")
        let group = try Self.group(inputs: [input, cursor, claude])
        let longMetrics = try Self.group(inputs: [Self.input(
            sampleSets: [high],
            partial: true,
            dailyCost: 12345.67,
            dailyTokens: 7_800_000_000,
            unpricedRequestCount: 3)])
        let longBreakdown = try #require(spendDashboardProviderBreakdowns(longMetrics).first)
        #expect(longBreakdown.totalCost == 12345.67)
        #expect(longBreakdown.totalTokens == 7_800_000_000)
        #expect(longBreakdown.incompleteRequestCount == 3)
        for language in ["en", "zh-Hans"] {
            for dark in [false, true] {
                try CodexBarLocalizationOverride.$appLanguage.withValue(language) {
                    let performance = try #require(spendDashboardProviderBreakdowns(group)
                        .first { $0.provider == .codex }?.performance)
                    try Self.render(
                        SpendHarnessRatingDetailsView(
                            performance: performance,
                            cacheSampleCount: 28,
                            historyScanIsPartial: false),
                        root: root,
                        name: "rating-details-\(language)-\(dark ? "dark" : "light")",
                        width: 480,
                        dark: dark)
                    try Self.render(
                        SpendHarnessRatingUnavailableDetailsView(),
                        root: root,
                        name: "rating-unavailable-\(language)-\(dark ? "dark" : "light")",
                        width: 480,
                        dark: dark)
                    let pendingPerformance = try #require(CostUsageTurnPerformanceSummary(samples: [missing, missing]))
                    try Self.render(
                        SpendHarnessRatingDetailsView(
                            performance: pendingPerformance,
                            cacheSampleCount: 0,
                            historyScanIsPartial: true),
                        root: root,
                        name: "rating-pending-\(language)-\(dark ? "dark" : "light")",
                        width: 480,
                        dark: dark)
                    for width in [360.0, 520.0, 980.0] {
                        let view = VStack(alignment: .leading, spacing: 18) {
                            Text(L("Usage & Spend")).font(.title2.bold())
                            Text(L("Providers")).font(.headline)
                            SpendDashboardPanel {
                                SpendProviderBreakdownRows(group: group)
                            }
                        }
                        try Self.render(
                            view,
                            root: root,
                            name: "providers-inline-\(language)-\(dark ? "dark" : "light")-\(Int(width))",
                            width: width,
                            dark: dark)
                    }
                    for width in [360.0, 520.0, 980.0] {
                        try Self.render(
                            SpendDashboardPanel {
                                SpendProviderBreakdownRows(group: longMetrics)
                            },
                            root: root,
                            name: "providers-long-metrics-\(language)-\(dark ? "dark" : "light")-\(Int(width))",
                            width: width,
                            dark: dark)
                    }
                    let view = SpendDashboardCurrencySection(group: group, requestedDays: 7, hidePersonalInfo: true)
                    try Self.render(
                        view,
                        root: root,
                        name: "dashboard-\(language)-\(dark ? "dark" : "light")",
                        width: 980,
                        dark: dark)
                }
            }
        }
    }

    private static func render(_ view: some View, root: URL, name: String, width: Double, dark: Bool) throws {
        let content = view
            .padding(20).frame(width: width)
            .background(dark ? Color(red: 0.12, green: 0.12, blue: 0.12) : .white)
            .foregroundStyle(dark ? .white : .black)
            .environment(\.colorScheme, dark ? .dark : .light)
        // Host native AppKit controls as well as SwiftUI content; ImageRenderer cannot export link buttons.
        let hosting = NSHostingView(rootView: content)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.appearance = appearance
        let size = hosting.fittingSize
        #expect(size.width > 0 && size.height > 0)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = appearance
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: root.appendingPathComponent("\(name).png"))
    }

    private static func sample(
        date: Date = Self.now,
        input: Int? = nil,
        cached: Int? = nil,
        duration: Int = 1000,
        output: Int = 100,
        firstToken: Int? = nil,
        model: String? = "gpt-5.4",
        effort: String? = "high") throws
        -> CostUsageTurnPerformanceSample
    {
        try #require(CostUsageTurnPerformanceSample(
            completedAt: date,
            outputTokens: output,
            durationMilliseconds: duration,
            firstTokenMilliseconds: firstToken,
            model: model,
            reasoningEffort: effort,
            inputTokens: input,
            cachedInputTokens: cached))
    }

    private static func input(
        id: String = "codex",
        sampleSets: [[CostUsageTurnPerformanceSample]],
        provider: UsageProvider = .codex,
        source: SpendDashboardModel.SourceKind = .native,
        partial: Bool = false,
        lastActivity: Date? = nil,
        includeModelHistory: Bool = false,
        displayName: String? = nil,
        dailyCost: Double = 0.1,
        dailyTokens: Int = 3000,
        unpricedRequestCount: Int? = nil) -> SpendDashboardModel.ProviderInput
    {
        let samples = sampleSets.flatMap(\.self)
        var models: [CostUsageDailyReport.ModelBreakdown]? = includeModelHistory && !samples.isEmpty
            ? Dictionary(grouping: samples, by: { $0.model ?? "example-test-model" }).map { model, observations in
                .init(
                    modelName: model,
                    costUSD: 0.1 * Double(observations.count) / Double(samples.count),
                    totalTokens: 3000 * observations.count / samples.count)
            } : nil
        if let unpricedRequestCount {
            models = (models ?? []) + [.init(
                modelName: "example-unpriced-model",
                costUSD: nil,
                totalTokens: nil,
                incompleteRequestCount: unpricedRequestCount)]
        }
        let sessions = sampleSets.enumerated().map { index, samples in
            CostUsageSessionBreakdown(
                sessionID: "synthetic-\(index)",
                lastActivity: lastActivity ?? Self.now,
                inputTokens: 2000,
                cachedInputTokens: 1000,
                outputTokens: 1000,
                totalTokens: 3000,
                requestCount: samples.count,
                costUSD: Double(index + 1) * 0.01,
                modelBreakdowns: [],
                projectPath: "/synthetic/project",
                projectName: "Example project",
                title: "Synthetic task \(index)",
                turnPerformanceSamples: samples)
        }
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 3000,
            sessionCostUSD: 0.1,
            last30DaysTokens: dailyTokens,
            last30DaysCostUSD: dailyCost,
            historyScanIsPartial: partial,
            daily: [.init(
                date: "2026-05-10",
                inputTokens: 2000,
                outputTokens: 1000,
                totalTokens: dailyTokens,
                costUSD: dailyCost,
                modelsUsed: nil,
                modelBreakdowns: models,
                unpricedRequestCount: unpricedRequestCount)],
            sessions: sessions,
            updatedAt: Self.now)
        return .init(
            id: id,
            provider: provider,
            displayName: displayName ?? "Synthetic source \(id)",
            snapshot: snapshot,
            sourceKind: source)
    }

    private static func group(
        inputs: [SpendDashboardModel.ProviderInput],
        selectedDay: Date? = nil,
        timeZone: TimeZone = .gmt,
        hiddenSourceIDs: Set<String> = [],
        includeSessionDetails: Bool = true) throws
        -> SpendDashboardModel.CurrencyGroup
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return try #require(SpendDashboardModel.build(
            inputs: inputs,
            requestedDays: 7,
            now: Self.now,
            calendar: calendar,
            hiddenSourceIDs: hiddenSourceIDs,
            selectedDay: selectedDay,
            includeSessionDetails: includeSessionDetails).groups.first)
    }
}

/// Opt-in synthetic measurements; ordinary regression runs do not execute these workloads.
extension SpendAgentProfileTests {
    private struct PerformanceMeasurement: Codable {
        let turns: Int
        let sessions: Int
        let modelBuildMilliseconds: [Double]
        let summaryBuildMilliseconds: [Double]
        let providerProjectionMilliseconds: [Double]
        let checksum: Int
    }

    @Test
    func `measure large synthetic harness histories when explicitly requested`() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_HARNESS_BENCHMARK_OUTPUT"] else { return }
        var measurements: [PerformanceMeasurement] = []
        for (sessionCount, turnsPerSession) in [(20, 20), (1000, 20), (2000, 50)] {
            let samples = try (0..<turnsPerSession).map { index in
                try Self.sample(
                    input: 10000 + index,
                    cached: 8000,
                    duration: 1000 + index * 731,
                    output: 100 + index * 43,
                    firstToken: 100 + index * 31,
                    model: "example-model-\(index % 8)",
                    effort: index.isMultiple(of: 2) ? "high" : "medium")
            }
            let input = Self.input(sampleSets: Array(repeating: samples, count: sessionCount))
            let group = try Self.group(inputs: [input])
            var buildTimes: [Double] = []
            var summaryTimes: [Double] = []
            var projectionTimes: [Double] = []
            var checksum = 0
            for iteration in 0..<13 {
                let start = ContinuousClock.now
                let rebuilt = try Self.group(inputs: [input])
                let buildTime = Self.milliseconds(start.duration(to: .now))
                let summaryStart = ContinuousClock.now
                let summary = try Self.group(inputs: [input], includeSessionDetails: false)
                let summaryTime = Self.milliseconds(summaryStart.duration(to: .now))
                let projectionStart = ContinuousClock.now
                let rows = spendDashboardProviderBreakdowns(group)
                let projectionTime = Self.milliseconds(projectionStart.duration(to: .now))
                checksum += rebuilt.agentProfiles.reduce(0) { $0 + $1.performance.sampleCount }
                checksum += rows.reduce(0) { $0 + ($1.performance?.sampleCount ?? 0) }
                #expect(summary.agentProfiles.isEmpty)
                #expect(summary.sessions.isEmpty)
                if iteration >= 2 {
                    buildTimes.append(buildTime)
                    summaryTimes.append(summaryTime)
                    projectionTimes.append(projectionTime)
                }
            }
            measurements.append(.init(
                turns: sessionCount * turnsPerSession,
                sessions: sessionCount,
                modelBuildMilliseconds: buildTimes,
                summaryBuildMilliseconds: summaryTimes,
                providerProjectionMilliseconds: projectionTimes,
                checksum: checksum))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(measurements).write(to: URL(fileURLWithPath: path))
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    @Test
    func `measure main actor responsiveness during background history projection when requested`() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_HARNESS_RESPONSIVENESS_OUTPUT"] else { return }
        let samples = try (0..<50).map { index in
            try Self.sample(
                input: 10000,
                cached: 8000,
                duration: 1000 + index * 731,
                output: 100 + index * 43,
                firstToken: 100 + index * 31,
                model: "example-model-\(index % 8)")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let request = SpendDashboardProjectionRequest(
            inputs: [Self.input(sampleSets: Array(repeating: samples, count: 2000))],
            reportingPeriod: .rolling(days: 7),
            now: Self.now,
            calendar: calendar,
            preferredCurrencyCode: "auto",
            hiddenSourceIDs: [],
            hideNativeCodexWhenOpenCodexPresent: false,
            selectedDay: nil)
        let heartbeat = Task { @MainActor in
            var gaps: [Double] = []
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(4)) } catch { break }
                let now = ContinuousClock.now
                gaps.append(Self.milliseconds(previous.duration(to: now)))
                previous = now
            }
            return gaps
        }
        defer { heartbeat.cancel() }
        try await Task.sleep(for: .milliseconds(8))
        let worker = SpendDashboardProjectionWorker()
        defer { worker.invalidate() }
        let start = ContinuousClock.now
        var enqueueTime = 0.0
        let model: SpendDashboardModel = await withCheckedContinuation { continuation in
            worker.submit(request) { continuation.resume(returning: $0) }
            enqueueTime = Self.milliseconds(start.duration(to: .now))
        }
        let completionTime = Self.milliseconds(start.duration(to: .now))
        heartbeat.cancel()
        let gaps = await heartbeat.value
        let count = model.groups.flatMap(\.providerBreakdowns).reduce(0) { $0 + ($1.performance?.sampleCount ?? 0) }
        #expect(count == 100_000)
        let metrics: [String: Any] = [
            "turns": count, "enqueueMilliseconds": enqueueTime, "completionMilliseconds": completionTime,
            "heartbeatTargetMilliseconds": 4, "heartbeatGapMilliseconds": gaps,
            "displayMaximumFramesPerSecond": NSScreen.main?.maximumFramesPerSecond ?? 0,
            "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
            "logicalProcessorCount": ProcessInfo.processInfo.processorCount,
        ]
        try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: path))
    }

    @Test
    func `measure full controller publication of large unchanged histories when requested`() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_HARNESS_PUBLICATION_OUTPUT"] else { return }
        let samples = try (0..<50).map { index in
            try Self.sample(
                input: 10000,
                cached: 8000,
                duration: 1000 + index * 731,
                output: 100 + index * 43,
                firstToken: 100 + index * 31,
                model: "example-model-\(index % 8)")
        }
        let input = Self.input(sampleSets: Array(repeating: samples, count: 2000))
        let configuration = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue],
            codexAccountIdentities: [],
            bucketTimeZoneIdentifier: "UTC")
        let suite = "SpendHarnessPublicationBenchmark-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let benchmarkNow = Self.now
        let controller = SpendDashboardController(
            userDefaults: defaults,
            requestBuilder: { mode in
                .init(
                    configuration: configuration,
                    capturedInputs: [input],
                    unavailableSourceIDs: [],
                    codexRequests: [],
                    now: Self.now,
                    force: mode.forcesLoader)
            },
            loader: { .init(inputs: $0.capturedInputs, failedSourceIDs: []) },
            nowProvider: { benchmarkNow })
        defer { controller.stop() }
        var measurements: [[String: Any]] = []
        for iteration in 0..<3 {
            let heartbeat = Task { @MainActor in
                var gaps: [Double] = []
                var previous = ContinuousClock.now
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(4)) } catch { break }
                    let now = ContinuousClock.now
                    gaps.append(Self.milliseconds(previous.duration(to: now)))
                    previous = now
                }
                return gaps
            }
            defer { heartbeat.cancel() }
            try await Task.sleep(for: .milliseconds(8))
            let start = ContinuousClock.now
            if iteration == 0 {
                controller.update(configuration: configuration)
            } else {
                controller.refresh()
            }
            let enqueueTime = Self.milliseconds(start.duration(to: .now))
            while controller.isRefreshing {
                try #require(start.duration(to: .now) < .seconds(30))
                try await Task.sleep(for: .milliseconds(1))
            }
            let completionTime = Self.milliseconds(start.duration(to: .now))
            heartbeat.cancel()
            let gaps = await heartbeat.value
            let count = controller.model.groups.flatMap(\.providerBreakdowns)
                .reduce(0) { $0 + ($1.performance?.sampleCount ?? 0) }
            #expect(count == 100_000)
            measurements.append([
                "iteration": iteration, "turns": count,
                "enqueueMilliseconds": enqueueTime, "completionMilliseconds": completionTime,
                "heartbeatTargetMilliseconds": 4, "heartbeatGapMilliseconds": gaps,
            ])
        }
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: path))
    }
}
