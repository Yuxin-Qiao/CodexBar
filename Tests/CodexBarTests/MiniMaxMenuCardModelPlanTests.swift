import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct MiniMaxMenuCardModelPlanTests {
    @Test
    func `minimax loginMethod maps to planText in MenuCardModel`() throws {
        let now = Date()
        let minimax = MiniMaxUsageSnapshot(
            planName: "MiniMax Star",
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: now)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            minimaxUsage: minimax,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .minimax,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "MiniMax Star"))
        let metadata = try #require(ProviderDefaults.metadata[.minimax])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .minimax,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.planText == "MiniMax Star")
    }

    @Test
    func `minimax nil loginMethod results in nil planText`() throws {
        let now = Date()
        let minimax = MiniMaxUsageSnapshot(
            planName: nil,
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: now)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            minimaxUsage: minimax,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .minimax,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil))
        let metadata = try #require(ProviderDefaults.metadata[.minimax])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .minimax,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.planText == nil)
    }

    @Test
    func `minimax usage notes surface tier expiry and credits`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expires = Date(timeIntervalSince1970: 1_800_000_000)
        let minimax = MiniMaxUsageSnapshot(
            planName: "TokenPlanPlus-月度会员",
            planTier: "Plus",
            planExpiresAt: expires,
            creditTotal: 28888,
            availablePrompts: 100,
            currentPrompts: 1,
            remainingPrompts: 99,
            windowMinutes: 300,
            usedPercent: 1,
            resetsAt: nil,
            updatedAt: now,
            services: [
                MiniMaxServiceUsage(
                    serviceType: "Text Generation",
                    windowType: "5 hours",
                    timeRange: "10:00-15:00(UTC+8)",
                    usage: 1,
                    limit: 100,
                    percent: 1,
                    resetsAt: now.addingTimeInterval(240),
                    resetDescription: "Resets in 4 min"),
            ])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 1, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            minimaxUsage: minimax,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .minimax,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "TokenPlanPlus-月度会员"))
        let metadata = try #require(ProviderDefaults.metadata[.minimax])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .minimax,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.planText == "TokenPlanPlus-月度会员")
        #expect(model.usageNotes.contains("Tier: Plus"))
        #expect(model.usageNotes.contains("Credits: 28,888"))
        #expect(model.usageNotes.contains(where: { $0.hasPrefix("Expires: ") }))
    }
}
