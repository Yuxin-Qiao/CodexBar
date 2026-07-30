import CodexBarCore
import Foundation
import Testing

@Suite(.serialized)
struct AntigravityWindowMinutesTests {
    @Test
    func `antigravity model quota derives windowMinutes from reset description`() throws {
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Claude 3.5 Sonnet",
                    modelId: "claude-3-5-sonnet",
                    remainingFraction: 0.8,
                    resetTime: Date(),
                    resetDescription: "5-hour session reset"),
                AntigravityModelQuota(
                    label: "Gemini 2.5 Pro",
                    modelId: "gemini-2-5-pro",
                    remainingFraction: 0.5,
                    resetTime: Date(),
                    resetDescription: "Weekly reset"),
            ],
            accountEmail: "test@example.com",
            accountPlan: "Pro",
            source: .remote)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.primary?.windowMinutes == 10080)
        #expect(usage.secondary?.windowMinutes == 300)
    }

    @Test
    func `antigravity model quota derives windowMinutes from model label when reset description is nil`() throws {
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 2.5 Pro (Weekly)",
                    modelId: "gemini-2-5-pro",
                    remainingFraction: 0.5,
                    resetTime: Date(),
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Claude 3.5 Sonnet (5-hour session)",
                    modelId: "claude-3-5-sonnet",
                    remainingFraction: 0.8,
                    resetTime: Date(),
                    resetDescription: nil),
            ],
            accountEmail: "test@example.com",
            accountPlan: "Pro",
            source: .remote)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.primary?.windowMinutes == 10080)
        #expect(usage.secondary?.windowMinutes == 300)
    }
}
