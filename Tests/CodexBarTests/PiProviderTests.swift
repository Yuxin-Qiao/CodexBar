import Foundation
import Testing
@testable import CodexBarCore

struct PiProviderTests {
    @Test
    func `pi provider exposes an independent aggregate token snapshot`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 2)
        let entries: [[String: Any]] = [
            [
                "type": "message",
                "timestamp": env.isoString(for: day),
                "message": [
                    "role": "assistant",
                    "provider": "openai-codex",
                    "model": "openai/gpt-5.4",
                    "timestamp": Int(day.timeIntervalSince1970 * 1000),
                    "usage": ["input": 20, "output": 5, "totalTokens": 25],
                ],
            ],
            [
                "type": "message",
                "timestamp": env.isoString(for: day),
                "message": [
                    "role": "assistant",
                    "provider": "anthropic",
                    "model": "claude-sonnet-4-6",
                    "timestamp": Int(day.timeIntervalSince1970 * 1000),
                    "usage": ["input": 4, "output": 1, "totalTokens": 5],
                ],
            ],
        ]
        _ = try env.writePiSessionFile(
            relativePath: "2026-04-02T10-00-00-000Z_aggregate.jsonl",
            contents: env.jsonl(entries))

        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .pi,
            now: day,
            historyDays: 1,
            allowPricingRefresh: false,
            scannerOptions: CostUsageScanner.Options(cacheRoot: env.cacheRoot),
            piScannerOptions: piOptions)

        #expect(snapshot.sessionTokens == 30)
        #expect(snapshot.last30DaysTokens == 30)
        #expect(snapshot.historyCoverageIsEstablished)
        #expect(snapshot.costProvenance == .listPriceEstimate)

        let cached = PiSessionCostScanner.loadCachedDailyReport(
            provider: .pi,
            since: day,
            until: day,
            now: day,
            cacheRoot: env.cacheRoot)
        #expect(cached?.summary?.totalTokens == 30)
    }

    @Test
    func `pi provider descriptor is registered for token history`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .pi)

        #expect(descriptor.metadata.displayName == "Pi")
        #expect(descriptor.tokenCost.supportsTokenCost)
        #expect(descriptor.tokenCost.supportsTokenSnapshot)
        #expect(descriptor.metadata.defaultEnabled == false)
    }
}
