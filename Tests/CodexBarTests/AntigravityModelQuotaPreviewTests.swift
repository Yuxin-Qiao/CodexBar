import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct AntigravityModelQuotaPreviewTests {
    @Test
    func `flat model quotas keep all raw rows but bound the menu and remove the repeated group title`() throws {
        let snapshot = try self.snapshot(fractions: Array(repeating: 1, count: 11))
        let menu = try self.model(snapshot: snapshot)
        let details = try self.model(snapshot: snapshot, details: true)

        #expect(snapshot.extraRateWindows?.count == 11)
        #expect(menu.metrics.count == 4)
        #expect(menu.metrics.map(\.id) == Array(details.metrics.prefix(4)).map(\.id))
        #expect(menu.metrics.allSatisfy { !$0.title.hasPrefix("All Models ") && $0.percent == 100 })
        #expect(menu.quotaPreviewNote != nil)
        #expect(details.metrics.count == 11)
        #expect(details.quotaPreviewNote == nil)
        #expect(snapshot.extraRateWindows?.allSatisfy { $0.window.windowMinutes == nil } == true)
    }

    @Test(arguments: [false, true])
    func `unknown quotas and lowest remaining models win regardless of percentage display mode`(showUsed: Bool) throws {
        let snapshot = try self.snapshot(fractions: [1, 0.9, 0.8, 0.7, 0.05, nil])
        let menu = try self.model(snapshot: snapshot, showUsed: showUsed)
        let details = try self.model(snapshot: snapshot, details: true, showUsed: showUsed)

        #expect(menu.metrics.map(\.id) == [5, 4, 3, 2].map { "antigravity-quota-summary-gemini-test-\($0)" })
        #expect(menu.metrics[0].statusText != nil)
        #expect(menu.metrics[1].percent == (showUsed ? 95 : 5))
        #expect(details.metrics.count == 6)
        #expect(details.metrics[1].percent == (showUsed ? 10 : 90))
    }

    @Test
    func `small model lists do not need a preview note`() throws {
        let model = try self.model(snapshot: self.snapshot(fractions: [1, 0.5]))
        #expect(model.metrics.count == 2)
        #expect(model.quotaPreviewNote == nil)
    }

    @Test
    func `explicit cadence summaries are not capped or relabeled`() throws {
        let snapshot = try self.snapshot(fractions: Array(repeating: 0.5, count: 6), window: "weekly")
        let model = try self.model(snapshot: snapshot)
        #expect(model.metrics.count == 6)
        #expect(model.metrics.allSatisfy { $0.title == "All Models weekly" })
        #expect(model.quotaPreviewNote == nil)
        #expect(snapshot.extraRateWindows?.allSatisfy { $0.window.windowMinutes == 10080 } == true)
    }

    private func snapshot(fractions: [Double?], window: String? = nil) throws -> UsageSnapshot {
        let buckets: [[String: Any]] = fractions.enumerated().map { index, fraction in
            var bucket: [String: Any] = [
                "bucketId": "gemini-test-\(index)",
                "displayName": "Gemini Test Model \(index)",
            ]
            if let fraction { bucket["remainingFraction"] = fraction }
            if let window { bucket["window"] = window }
            return bucket
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "groups": [["displayName": "All Models", "buckets": buckets]],
        ])
        return try AntigravityStatusProbe.parseQuotaSummaryResponse(data).toUsageSnapshot()
    }

    private func model(
        snapshot: UsageSnapshot,
        details: Bool = false,
        showUsed: Bool = false) throws -> UsageMenuCardView.Model
    {
        try UsageMenuCardView.Model.make(.init(
            provider: .antigravity,
            metadata: #require(ProviderDefaults.metadata[.antigravity]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: showUsed,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            showsAllUsageLanes: details,
            hidePersonalInfo: false,
            now: snapshot.updatedAt))
    }
}
