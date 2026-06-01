import Foundation
import Testing
@testable import CodexBarCore

struct MiniMaxUsageSnapshotEncodingTests {
    @Test
    func `usage snapshot json preserves token plan fields and service windows`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset5h = now.addingTimeInterval(4 * 60 * 60)
        let resetWeekly = now.addingTimeInterval(3 * 24 * 60 * 60)
        let expires = now.addingTimeInterval(30 * 24 * 60 * 60)
        let minimax = MiniMaxUsageSnapshot(
            planName: "TokenPlanPlus-月度会员",
            planTier: "Plus",
            planExpiresAt: expires,
            creditTotal: 28888,
            availablePrompts: 1000,
            currentPrompts: 10,
            remainingPrompts: 990,
            windowMinutes: 300,
            usedPercent: 1,
            resetsAt: reset5h,
            updatedAt: now,
            services: [
                MiniMaxServiceUsage(
                    serviceType: "Text Generation",
                    windowType: "5 hours",
                    timeRange: "10:00-15:00(UTC+8)",
                    usage: 10,
                    limit: 1000,
                    percent: 1,
                    resetsAt: reset5h,
                    resetDescription: "Resets in 4 hours"),
                MiniMaxServiceUsage(
                    serviceType: "Text Generation",
                    windowType: "Weekly",
                    timeRange: "2026/06/01 00:00 - 2026/06/08 00:00(UTC+8)",
                    usage: 20,
                    limit: 2000,
                    percent: 1,
                    resetsAt: resetWeekly,
                    resetDescription: "Resets in 3 days"),
            ])

        let usage = minimax.toUsageSnapshot()
        let data = try JSONEncoder().encode(usage)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedMiniMax = try #require(payload["minimaxUsage"] as? [String: Any])
        #expect(encodedMiniMax["planName"] as? String == "TokenPlanPlus-月度会员")
        #expect(encodedMiniMax["planTier"] as? String == "Plus")
        #expect(encodedMiniMax["creditTotal"] as? Int == 28888)

        let services = try #require(encodedMiniMax["services"] as? [[String: Any]])
        #expect(services.count == 2)
        #expect(services[0]["windowType"] as? String == "5 hours")
        #expect(services[1]["windowType"] as? String == "Weekly")

        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.usedPercent == 1)
        #expect(usage.secondary?.windowMinutes == nil)
        #expect(usage.secondary?.usedPercent == 1)
    }
}
