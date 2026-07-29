import Foundation
import Testing
@testable import CodexBar

struct SpendModelsPresentationTests {
    @Test
    func `dashboard range labels stay English and preserve compact order`() {
        #expect([7, 30, 365].map(spendDashboardDayRangeText) == ["7d", "30d", "Cumulative"])
    }

    @Test
    func `model card date labels follow the app locale`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 2)))

        let expected = day.formatted(.dateTime.month(.abbreviated).day().locale(.autoupdatingCurrent))
        #expect(SpendModelsDateFormatter.dayText(day) == expected)
    }

    @Test
    func `All axis keeps endpoints without crowded trailing labels`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 2)))
        let last = try #require(calendar.date(byAdding: .day, value: 78, to: start))
        let domainEnd = try #require(calendar.date(byAdding: .day, value: 79, to: start))

        let dates = SpendModelsAxisDates.make(
            selectedDays: 365,
            dataDays: [start, last],
            domain: start...domainEnd,
            calendar: calendar)

        #expect(dates.count == 6)
        #expect(dates.first == start)
        #expect(dates.last == last)
        for pair in zip(dates, dates.dropFirst()) {
            let gap = calendar.dateComponents([.day], from: pair.0, to: pair.1).day
            #expect((gap ?? 0) >= 8)
        }
    }

    @Test
    func `All axis replaces a near-duplicate trailing tick with the latest day`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        let last = try #require(calendar.date(byAdding: .day, value: 57, to: start))
        let domainEnd = try #require(calendar.date(byAdding: .day, value: 58, to: start))

        let dates = SpendModelsAxisDates.make(
            selectedDays: 365,
            dataDays: [start, last],
            domain: start...domainEnd,
            calendar: calendar)

        #expect(dates.count == 5)
        #expect(dates.last == last)
        let trailingGap = try #require(calendar.dateComponents(
            [.day],
            from: dates[dates.count - 2],
            to: dates[dates.count - 1]).day)
        #expect(trailingGap >= 8)
    }

    @Test
    func `every model remains a named chart series`() {
        let analysis = SpendDashboardModel.ModelAnalysis(
            rows: (1...6).map { index in
                Self.row(id: "model-\(index)", tokens: index * 10, cost: Double(index))
            },
            dailyValues: [
                .init(
                    modelID: "model-6",
                    modelName: "model-6",
                    day: Self.day,
                    totalTokens: 60,
                    inputTokens: 50,
                    outputTokens: 10,
                    estimatedCost: 6),
                .init(
                    modelID: "model-1",
                    modelName: "model-1",
                    day: Self.day,
                    totalTokens: 10,
                    inputTokens: 8,
                    outputTokens: 2,
                    estimatedCost: 1),
            ],
            trackedTokenTotal: 210,
            pricedCostTotal: 21,
            sourceCount: 1,
            tokenCoverage: .complete,
            costCoverage: .complete)
        let presentation = SpendModelsPresentation(analysis: analysis, metric: .tokens)

        #expect(presentation.rows.map(\.source.id) == [
            "model-6",
            "model-5",
            "model-4",
            "model-3",
            "model-2",
            "model-1",
        ])
        #expect(presentation.series.map(\.id) == [
            "model-6",
            "model-5",
            "model-4",
            "model-3",
            "model-2",
            "model-1",
        ])
        #expect(presentation.series.last?.name == "model-1")
        #expect(presentation.series.last?.value == 10)
        #expect(presentation.points.map(\.seriesID) == ["model-6", "model-1"])
        #expect(presentation.points.map(\.stackStart) == [0, 60])
        #expect(presentation.points.map(\.stackEnd) == [60, 70])
    }

    @Test
    func `token rows show in and out only when the split is complete`() {
        let complete = SpendModelsPresentation.Row(
            source: Self.row(
                id: "complete",
                tokens: 100,
                inputTokens: 80,
                outputTokens: 20,
                cost: nil,
                providers: ["Codex"]),
            rank: 1,
            value: 100,
            share: 1)
        let totalOnly = SpendModelsPresentation.Row(
            source: Self.row(
                id: "total",
                tokens: 96,
                cost: nil,
                providers: ["Kimi"]),
            rank: 2,
            value: 96,
            share: 1)

        #expect(spendModelsRowDetailText(complete) == "80 in · 20 out · Codex")
        #expect(spendModelsRowDetailText(totalOnly) == "96 · Kimi")
    }

    @Test
    func `spend metric ranks priced rows before rows with no price`() {
        let analysis = SpendDashboardModel.ModelAnalysis(
            rows: [
                Self.row(id: "unpriced", tokens: 1000, cost: nil),
                Self.row(id: "priced", tokens: 10, cost: 2),
            ],
            dailyValues: [],
            trackedTokenTotal: 1010,
            pricedCostTotal: 2,
            sourceCount: 1,
            tokenCoverage: .complete,
            costCoverage: .partial)
        let presentation = SpendModelsPresentation(analysis: analysis, metric: .estimatedSpend)

        #expect(presentation.rows.map(\.source.id) == ["priced", "unpriced"])
        #expect(presentation.rows.first?.share == 1)
        #expect(presentation.rows.last?.share == nil)
        #expect(presentation.coverage == .partial)
    }

    @Test
    func `ranking primary value uses the selected metric unit`() {
        let row = SpendModelsPresentation.Row(
            source: Self.row(id: "priced", tokens: 632_000_000, cost: 89.29),
            rank: 1,
            value: 89.29,
            share: 1)

        #expect(spendModelsRankingValueText(row, metric: .tokens) == "632M")
        #expect(spendModelsRankingValueText(row, metric: .estimatedSpend) == "$89.29")
    }

    @Test
    func `ranking context keeps only the complementary metric`() {
        let bucketed = SpendModelsPresentation.Row(
            source: Self.row(
                id: "bucketed",
                tokens: 500_000_000,
                inputTokens: 19_000_000,
                outputTokens: 930_000,
                cost: 405.12),
            rank: 1,
            value: 500_000_000,
            share: 1)
        let aggregateOnly = SpendModelsPresentation.Row(
            source: Self.row(id: "aggregate", tokens: 632_000_000, cost: 89.29),
            rank: 2,
            value: 632_000_000,
            share: 1)

        #expect(spendModelsRankingContextText(bucketed, metric: .tokens) == "$405.12")
        #expect(spendModelsRankingContextText(aggregateOnly, metric: .tokens) == "$89.29")
        #expect(spendModelsRankingContextText(aggregateOnly, metric: .estimatedSpend) == "632M tokens")
        CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            #expect(spendModelsRankingContextText(aggregateOnly, metric: .estimatedSpend) == "632M 令牌")
        }
    }

    @Test
    func `chart values follow the selected metric unit`() {
        #expect(spendModelsChartMetricText(632_000_000, metric: .tokens) == "632M")
        #expect(spendModelsChartMetricText(89.29, metric: .estimatedSpend) == "$89.29")
    }

    @Test
    func `estimated spend chart uses daily costs for bar heights`() {
        let analysis = SpendDashboardModel.ModelAnalysis(
            rows: [
                Self.row(id: "expensive", tokens: 10, cost: 8),
                Self.row(id: "token-heavy", tokens: 1000, cost: 2),
            ],
            dailyValues: [
                Self.dailyValue(modelID: "expensive", day: Self.day, totalTokens: 10, cost: 8),
                Self.dailyValue(modelID: "token-heavy", day: Self.day, totalTokens: 1000, cost: 2),
            ],
            trackedTokenTotal: 1010,
            pricedCostTotal: 10,
            sourceCount: 1,
            tokenCoverage: .complete,
            costCoverage: .complete)

        let tokens = SpendModelsPresentation(analysis: analysis, metric: .tokens)
        let spend = SpendModelsPresentation(analysis: analysis, metric: .estimatedSpend)

        #expect(tokens.points.map(\.value) == [1000, 10])
        #expect(tokens.points.last?.stackEnd == 1010)
        #expect(spend.points.map(\.value) == [8, 2])
        #expect(spend.points.last?.stackEnd == 10)
        #expect(spend.dailyTotals.map(\.value) == [10])
        #expect(spend.dailyTotals.first?.stackStart == 0)
        #expect(spend.dailyTotals.first?.stackEnd == 10)
    }

    @Test
    func `ranking keeps every row visible at the collapsed limit`() {
        #expect(SpendModelsRanking.collapsedRowLimit == 5)
        let rows = Self.rankingRows(count: SpendModelsRanking.collapsedRowLimit)

        #expect(!SpendModelsRanking.showsDisclosure(rowCount: rows.count))
        #expect(SpendModelsRanking.visibleRows(rows, showsAll: false).map(\.id) == rows.map(\.id))
        #expect(SpendModelsRanking.visibleRows(rows, showsAll: true).map(\.id) == rows.map(\.id))
    }

    @Test
    func `ranking truncates rows beyond the collapsed limit until expanded`() {
        let rows = Self.rankingRows(count: SpendModelsRanking.collapsedRowLimit + 5)

        #expect(SpendModelsRanking.showsDisclosure(rowCount: rows.count))

        let collapsed = SpendModelsRanking.visibleRows(rows, showsAll: false)
        #expect(collapsed.count == SpendModelsRanking.collapsedRowLimit)
        #expect(collapsed.map(\.id) == rows.prefix(SpendModelsRanking.collapsedRowLimit).map(\.id))
        #expect(collapsed.last?.rank == SpendModelsRanking.collapsedRowLimit)

        let expanded = SpendModelsRanking.visibleRows(rows, showsAll: true)
        #expect(expanded.map(\.id) == rows.map(\.id))
    }

    @Test
    func `dashboard range labels localize with the app language`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            #expect([7, 30, 365].map(spendDashboardDayRangeText) == ["7 天", "30 天", "累计"])
        }
    }

    @Test
    func `token row detail localizes the in and out split`() {
        let row = SpendModelsPresentation.Row(
            source: Self.row(
                id: "complete",
                tokens: 100,
                inputTokens: 80,
                outputTokens: 20,
                cost: nil,
                providers: ["Codex"]),
            rank: 1,
            value: 100,
            share: 1)

        CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            #expect(spendModelsRowDetailText(row) == "80 输入 · 20 输出 · Codex")
        }
    }

    @Test
    func `trailing average smooths each series over fewer samples at the window edge`() {
        let days = (0..<4).map { Self.day.addingTimeInterval(Double($0) * 86400) }
        let analysis = SpendDashboardModel.ModelAnalysis(
            rows: [Self.row(id: "model-a", tokens: 100, cost: nil)],
            dailyValues: zip(days, [10, 20, 30, 40]).map { day, tokens in
                Self.dailyValue(modelID: "model-a", day: day, totalTokens: tokens)
            },
            trackedTokenTotal: 100,
            pricedCostTotal: nil,
            sourceCount: 1,
            tokenCoverage: .complete,
            costCoverage: .partial)

        let smoothed = SpendModelsPresentation(analysis: analysis, metric: .tokens).applyingTrailingAverage()

        #expect(SpendModelsPresentation.trailingAverageWindow == 7)
        #expect(smoothed.points.map(\.day) == days)
        #expect(smoothed.points.map(\.value) == [10, 15, 20, 25])
        #expect(smoothed.points.map(\.stackStart) == [0, 0, 0, 0])
        #expect(smoothed.points.map(\.stackEnd) == [10, 15, 20, 25])
        // Ranking stays raw: only the chart points are smoothed.
        #expect(smoothed.rows.map(\.value) == [100])
        #expect(smoothed.series.map(\.value) == [100])
    }

    @Test
    func `trailing average treats days without series data as zero samples`() {
        let days = (0..<4).map { Self.day.addingTimeInterval(Double($0) * 86400) }
        let analysis = SpendDashboardModel.ModelAnalysis(
            rows: [
                Self.row(id: "model-a", tokens: 70, cost: nil),
                Self.row(id: "model-b", tokens: 40, cost: nil),
            ],
            dailyValues: [
                Self.dailyValue(modelID: "model-a", day: days[0], totalTokens: 10),
                Self.dailyValue(modelID: "model-a", day: days[1], totalTokens: 20),
                Self.dailyValue(modelID: "model-a", day: days[3], totalTokens: 40),
                Self.dailyValue(modelID: "model-b", day: days[0], totalTokens: 4),
                Self.dailyValue(modelID: "model-b", day: days[1], totalTokens: 8),
                Self.dailyValue(modelID: "model-b", day: days[2], totalTokens: 12),
                Self.dailyValue(modelID: "model-b", day: days[3], totalTokens: 16),
            ],
            trackedTokenTotal: 110,
            pricedCostTotal: nil,
            sourceCount: 1,
            tokenCoverage: .complete,
            costCoverage: .partial)

        let smoothed = SpendModelsPresentation(analysis: analysis, metric: .tokens)
            .applyingTrailingAverage(window: 2)

        // model-a: [10, 15, 10, 20]; model-b: [4, 6, 10, 14]. Series stack in ranking order.
        #expect(smoothed.points.map(\.seriesID) == [
            "model-a", "model-b",
            "model-a", "model-b",
            "model-a", "model-b",
            "model-a", "model-b",
        ])
        #expect(smoothed.points.map(\.value) == [10, 4, 15, 6, 10, 10, 20, 14])
        #expect(smoothed.points.map(\.stackStart) == [0, 10, 0, 15, 0, 10, 0, 20])
        #expect(smoothed.points.map(\.stackEnd) == [10, 14, 15, 21, 10, 20, 20, 34])
    }

    @Test
    func `day detail aggregates buckets and sorts models by tokens`() throws {
        let analysis = SpendDashboardModel.ModelAnalysis(
            rows: [
                Self.row(
                    id: "model-a",
                    tokens: 130,
                    cost: 1.5,
                    providers: ["Codex"],
                    costIsEstimated: true),
                Self.row(id: "model-b", tokens: 50, cost: 0.5, providers: ["Kimi"]),
            ],
            dailyValues: [
                Self.dailyValue(
                    modelID: "model-a",
                    day: Self.day,
                    totalTokens: 100,
                    inputTokens: 80,
                    outputTokens: 20,
                    cost: 1.5,
                    cacheReadTokens: 15,
                    cacheCreationTokens: 5,
                    reasoningTokens: 4),
                Self.dailyValue(
                    modelID: "model-b",
                    day: Self.day,
                    totalTokens: 50,
                    inputTokens: 30,
                    outputTokens: 20,
                    cost: 0.5),
            ],
            trackedTokenTotal: 180,
            pricedCostTotal: 2,
            sourceCount: 2,
            tokenCoverage: .complete,
            costCoverage: .complete)

        let detail = try #require(SpendModelsDayDetailPresentation(
            analysis: analysis,
            day: Self.day,
            metric: .estimatedSpend))

        #expect(detail.totalTokens == 150)
        #expect(detail.totalCost == 2)
        #expect(detail.buckets.map(\.kind) == [.input, .output, .cacheRead, .cacheWrite, .reasoning])
        #expect(detail.buckets.map(\.tokens) == [110, 40, 15, 5, 4])

        #expect(detail.models.map(\.id) == ["model-a", "model-b"])
        #expect(detail.pricedModelCount == 2)
        let first = try #require(detail.models.first)
        #expect(first.modelProvider == .openai)
        #expect(first.providerNames == ["Codex"])
        #expect(first.costIsEstimated)
        #expect(first.buckets.map(\.kind) == [.input, .output, .cacheRead, .cacheWrite, .reasoning])
        #expect(first.buckets.map(\.tokens) == [80, 20, 15, 5, 4])
        #expect(detail.models.last?.buckets.map(\.kind) == [.input, .output])
    }

    @Test
    func `day detail model summary keeps bucket splits behind disclosure`() {
        let priced = SpendModelsDayDetailPresentation.Model(
            id: "priced",
            name: "Priced",
            modelProvider: .openai,
            providerNames: ["Codex"],
            totalTokens: 80,
            cost: 8,
            costIsEstimated: true,
            buckets: [
                .init(kind: .input, tokens: 60),
                .init(kind: .output, tokens: 20),
            ])
        let unpriced = SpendModelsDayDetailPresentation.Model(
            id: "unpriced",
            name: "Unpriced",
            modelProvider: .gemini,
            providerNames: ["Antigravity"],
            totalTokens: 20,
            cost: nil,
            costIsEstimated: false,
            buckets: [])

        #expect(spendModelsDayDetailModelSummaryText(
            priced,
            metric: .tokens,
            totalTokens: 100,
            totalCost: 8) == "80 · 80%")
        #expect(spendModelsDayDetailModelSummaryText(
            priced,
            metric: .estimatedSpend,
            totalTokens: 100,
            totalCost: 8) == "$8.00 · 100%")
        #expect(spendModelsDayDetailModelSummaryText(
            unpriced,
            metric: .estimatedSpend,
            totalTokens: 100,
            totalCost: 8) == "20 · Unavailable")
        CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            #expect(spendModelsDayDetailModelSummaryText(
                unpriced,
                metric: .estimatedSpend,
                totalTokens: 100,
                totalCost: 8) == "20 · 不可用")
        }
        #expect(spendModelsDayDetailModelSplitText(priced) == "60 in · 20 out")
    }

    @Test
    func `day detail hides the category bar when no bucket data exists`() throws {
        let analysis = SpendDashboardModel.ModelAnalysis(
            rows: [Self.row(id: "model-a", tokens: 50, cost: nil)],
            dailyValues: [
                Self.dailyValue(modelID: "model-a", day: Self.day, totalTokens: 50),
            ],
            trackedTokenTotal: 50,
            pricedCostTotal: nil,
            sourceCount: 1,
            tokenCoverage: .complete,
            costCoverage: .partial)

        let detail = try #require(SpendModelsDayDetailPresentation(
            analysis: analysis,
            day: Self.day,
            metric: .tokens))

        #expect(detail.buckets.isEmpty)
        let model = try #require(detail.models.first)
        #expect(model.buckets.isEmpty)
        #expect(spendModelsDayDetailModelSplitText(model) == "50")
    }

    @Test
    func `day detail is nil outside the charted range and matches inside`() {
        let analysis = SpendDashboardModel.ModelAnalysis(
            rows: [Self.row(id: "model-a", tokens: 10, cost: nil)],
            dailyValues: [
                Self.dailyValue(modelID: "model-a", day: Self.day, totalTokens: 10),
            ],
            trackedTokenTotal: 10,
            pricedCostTotal: nil,
            sourceCount: 1,
            tokenCoverage: .complete,
            costCoverage: .partial)
        let presentation = SpendModelsPresentation(analysis: analysis, metric: .tokens)
        let outside = Self.day.addingTimeInterval(10 * 86400)

        #expect(presentation.day(matching: Self.day) == Self.day)
        #expect(presentation.day(matching: outside) == nil)
        #expect(SpendModelsDayDetailPresentation(analysis: analysis, day: outside, metric: .tokens) == nil)
    }

    @Test
    func `day detail bucket text localizes the cache read label`() {
        let bucket = SpendModelsDayDetailPresentation.Bucket(kind: .cacheRead, tokens: 15)

        CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            #expect(spendModelsDayDetailBucketText(bucket) == "15 缓存读取")
        }
    }

    private static func row(
        id: String,
        tokens: Int?,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cost: Double?,
        providers: [String] = [],
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        costIsEstimated: Bool = false) -> SpendDashboardModel.ModelAnalysisRow
    {
        SpendDashboardModel.ModelAnalysisRow(
            id: id,
            displayName: id,
            rawModelNames: [id],
            providers: [],
            providerNames: providers,
            contributions: [],
            totalTokens: tokens,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            estimatedCost: cost,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            reasoningTokens: reasoningTokens,
            costIsEstimated: costIsEstimated)
    }

    private static func dailyValue(
        modelID: String,
        day: Date,
        totalTokens: Int?,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cost: Double? = nil,
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil,
        reasoningTokens: Int? = nil) -> SpendDashboardModel.ModelDailyValue
    {
        SpendDashboardModel.ModelDailyValue(
            modelID: modelID,
            modelName: modelID,
            day: day,
            totalTokens: totalTokens,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            estimatedCost: cost,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            reasoningTokens: reasoningTokens)
    }

    private static func rankingRows(count: Int) -> [SpendModelsPresentation.Row] {
        (1...count).map { index in
            SpendModelsPresentation.Row(
                source: Self.row(id: "model-\(index)", tokens: index, cost: nil),
                rank: index,
                value: Double(index),
                share: nil)
        }
    }

    private static let day = Date(timeIntervalSince1970: 1_784_179_200)
}
