import CodexBarCore
import Foundation
import Observation
import Testing
@testable import CodexBar

@MainActor
struct SpendDashboardProjectionTests {
    private static let now = Date(timeIntervalSince1970: 1_778_414_400)

    @Test(arguments: ["UTC", "Asia/Shanghai", "America/Los_Angeles", "America/Santiago"])
    func `instant filtering preserves calendar days and excludes the next midnight through DST`(zone: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        for month in [3, 9, 11] {
            let day = month == 3 ? 7 : month == 9 ? 5 : 1
            let start = try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: day)))
            let lastDay = try #require(calendar.date(byAdding: .day, value: 3, to: start))
            let bounds = start...lastDay
            for selected in [nil, start, lastDay] {
                let interval = try #require(SpendDashboardModel.performanceInterval(
                    bounds: bounds, calendar: calendar, selectedDay: selected))
                for offset in -24..<150 {
                    let date = start.addingTimeInterval(Double(offset) * 3600)
                    let day = calendar.startOfDay(for: date)
                    let expected = bounds.contains(day) && (selected == nil || day == selected)
                    #expect(interval.contains(date) == expected)
                }
                #expect(!interval.contains(interval.upperBound))
            }
            #expect(SpendDashboardModel.performanceInterval(
                bounds: bounds, calendar: calendar, selectedDay: start.addingTimeInterval(-86400)) == nil)
        }
    }

    @Test
    func `rapid changes keep one active build and only the latest pending snapshot`() async throws {
        let gate = SpendDashboardPendingLoads<Void>()
        defer { gate.close() }
        let recorder = SpendDashboardProjectionRecorder()
        let worker = SpendDashboardProjectionWorker { request in
            await recorder.record(request)
            try? await gate.load()
            return request.build()
        }
        defer { worker.invalidate() }
        worker.submit(Self.request(tokens: 1)) { _ in recorder.published.append(1) }
        try await gate.waitForPendingCount(1)
        for tokens in 2...100 {
            worker.submit(Self.request(tokens: tokens)) { _ in recorder.published.append(tokens) }
        }
        #expect(recorder.started == [1])
        #expect(gate.pendingCount == 1)
        gate.resume(returning: ())
        try await SpendDashboardStateWait.until { recorder.started == [1, 100] }
        try await gate.waitForPendingCount(1)
        #expect(recorder.published.isEmpty)
        gate.resume(returning: ())
        try await SpendDashboardStateWait.until { recorder.published == [100] }
    }

    @Test
    func `invalidation discards active and pending work before a reopened view publishes`() async throws {
        let gate = SpendDashboardPendingLoads<Void>()
        defer { gate.close() }
        let recorder = SpendDashboardProjectionRecorder()
        let worker = SpendDashboardProjectionWorker { request in
            await recorder.record(request)
            try? await gate.load()
            return request.build()
        }
        defer { worker.invalidate() }
        worker.submit(Self.request(tokens: 1)) { _ in recorder.published.append(1) }
        try await gate.waitForPendingCount(1)
        worker.submit(Self.request(tokens: 2)) { _ in recorder.published.append(2) }
        worker.invalidate()
        worker.submit(Self.request(tokens: 3)) { _ in recorder.published.append(3) }
        #expect(recorder.started == [1])
        gate.resume(returning: ())
        try await SpendDashboardStateWait.until { recorder.started == [1, 3] }
        try await gate.waitForPendingCount(1)
        #expect(recorder.published.isEmpty)
        gate.resume(returning: ())
        try await SpendDashboardStateWait.until { recorder.published == [3] }
    }

    @Test
    func `refresh stays busy until the current filtered model and prepared scores are ready`() async throws {
        let gate = SpendDashboardPendingLoads<Void>()
        defer { gate.close() }
        let controller = Self.controller(gate: gate)
        defer { controller.stop() }
        controller.update(configuration: Self.configuration())
        try await gate.waitForPendingCount(1)
        #expect(controller.isRefreshing)
        #expect(controller.isProjecting)
        #expect(controller.model.groups.isEmpty)
        controller.selectDay(Self.now)
        controller.selectPeriod(.rolling(days: 7))
        gate.resume(returning: ())
        try await gate.waitForPendingCount(1)
        #expect(controller.model.groups.isEmpty)
        #expect(controller.isRefreshing)
        gate.resume(returning: ())
        try await SpendDashboardStateWait.until { !controller.isRefreshing }
        #expect(controller.model.requestedDays == 7)
        #expect(controller.model.selectedDay == Self.request(tokens: 5).calendar.startOfDay(for: Self.now))
        #expect(controller.model.groups.first?.providerBreakdowns.first?.performance?.sampleCount == 5)
        #expect(controller.publication.isRefreshing == false)
    }

    @Test
    func `hiding sources clears displayed scores immediately and stopped work cannot restore them`() async throws {
        let gate = SpendDashboardPendingLoads<Void>()
        defer { gate.close() }
        let controller = Self.controller(gate: gate)
        controller.update(configuration: Self.configuration())
        try await gate.waitForPendingCount(1)
        gate.resume(returning: ())
        try await SpendDashboardStateWait.until { !controller.isRefreshing }
        #expect(controller.model.groups.first?.providerBreakdowns.first?.performance != nil)
        controller.selectPeriod(.rolling(days: 7))
        try await gate.waitForPendingCount(1)
        controller.update(configuration: Self.configuration(hidden: true))
        #expect(controller.model.groups.isEmpty)
        controller.stop()
        gate.resume(returning: ())
        try await SpendDashboardStateWait.until { gate.pendingCount == 0 }
        await Task.yield()
        #expect(controller.model.groups.isEmpty)
        #expect(!controller.isProjecting)
        #expect(!controller.isRefreshing)
    }

    private static func controller(gate: SpendDashboardPendingLoads<Void>) -> SpendDashboardController {
        SpendDashboardController(
            userDefaults: UserDefaults(suiteName: "SpendDashboardProjectionTests-\(UUID().uuidString)")!,
            requestBuilder: { mode in
                SpendDashboardLoadRequest(
                    configuration: Self.configuration(),
                    capturedInputs: Self.request(tokens: 5).inputs,
                    unavailableSourceIDs: [],
                    codexRequests: [],
                    now: Self.now,
                    force: mode.forcesLoader)
            },
            loader: { .init(inputs: $0.capturedInputs, failedSourceIDs: []) },
            modelBuilder: { request in
                try? await gate.load()
                return request.build()
            })
    }

    private static func configuration(hidden: Bool = false) -> SpendDashboardConfiguration {
        .init(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue],
            codexAccountIdentities: [],
            bucketTimeZoneIdentifier: "UTC",
            hiddenSourceIDs: hidden ? ["synthetic-codex"] : [])
    }

    private static func request(tokens: Int) -> SpendDashboardProjectionRequest {
        let sample = CostUsageTurnPerformanceSample(
            completedAt: Self.now,
            outputTokens: 100,
            durationMilliseconds: 1000,
            firstTokenMilliseconds: 100,
            model: "example-model",
            inputTokens: 1000,
            cachedInputTokens: 800)!
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: tokens,
            sessionCostUSD: 1,
            last30DaysTokens: tokens,
            last30DaysCostUSD: 1,
            daily: [.init(
                date: "2026-05-10",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: tokens,
                costUSD: 1,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            sessions: [.init(
                sessionID: "synthetic-session",
                lastActivity: Self.now,
                inputTokens: 1000,
                cachedInputTokens: 800,
                outputTokens: 100,
                totalTokens: tokens,
                requestCount: 5,
                costUSD: 1,
                modelBreakdowns: [],
                turnPerformanceSamples: Array(repeating: sample, count: 5))],
            updatedAt: Self.now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return .init(
            inputs: [.init(id: "synthetic-codex", provider: .codex, displayName: "Codex", snapshot: snapshot)],
            reportingPeriod: .rolling(days: 30),
            now: Self.now,
            calendar: calendar,
            preferredCurrencyCode: "auto",
            hiddenSourceIDs: [],
            hideNativeCodexWhenOpenCodexPresent: false,
            selectedDay: nil)
    }
}

@MainActor
@Observable
final class SpendDashboardProjectionRecorder {
    var started: [Int] = []
    var published: [Int] = []

    func record(_ request: SpendDashboardProjectionRequest) {
        self.started.append(request.inputs.first?.snapshot.sessionTokens ?? 0)
    }
}
