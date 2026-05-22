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
    func `minimax menu card omits plan period ends metric when planPeriodEndsAt is nil`() throws {
        // Without a reliable billing-period source, planPeriodEndsAt stays nil from parsing.
        // The menu card should not render a plan-period row when planPeriodEndsAt is nil.
        let now = Date()
        let minimax = MiniMaxUsageSnapshot(
            planName: "Max",
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: now,
            services: [
                MiniMaxServiceUsage(
                    serviceType: "text-generation",
                    windowType: "5 hours",
                    timeRange: "10:00-15:00(UTC+8)",
                    usage: 2,
                    limit: 10,
                    percent: 20,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: "Resets in 1 hour"),
            ],
            planPeriodEndsAt: nil)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            minimaxUsage: minimax,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .minimax,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Max"))
        let metadata = try #require(ProviderDefaults.metadata[.minimax])

        let model = try #require(UsageMenuCardView.Model.make(.init(
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
            now: now)))

        let planPeriodMetric = model.metrics.first { $0.id == "minimax-plan-period" }
        #expect(planPeriodMetric == nil)
    }
}
