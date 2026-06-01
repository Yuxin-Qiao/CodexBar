import Foundation
import Testing
@testable import CodexBarCore

struct MiniMaxTokenPlanParserTests {
    @Test
    func `zero usage remains percent maps to zero used`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
          "base_resp": { "status_code": 0 },
          "model_remains": [
            {
              "model_name": "general",
              "current_interval_remaining_percent": 100,
              "remains_time": 240000
            }
          ]
        }
        """
        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8), now: now)
        #expect(snapshot.usedPercent == 0)
        #expect(snapshot.currentPrompts == 0)
    }

    @Test
    func `non zero remains percent maps to used and reset windows`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
          "base_resp": { "status_code": 0 },
          "model_remains": [
            {
              "model_name": "general",
              "current_interval_remaining_percent": 99,
              "current_weekly_remaining_percent": 99,
              "remains_time": 240000,
              "weekly_remains_time": 604800000
            }
          ]
        }
        """
        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8), now: now)
        #expect(snapshot.usedPercent == 1)
        #expect(snapshot.resetsAt == now.addingTimeInterval(240))
        let services = try #require(snapshot.services)
        let weekly = try #require(services.first(where: { $0.windowType == "Weekly" }))
        #expect(weekly.percent == 1)
        #expect(weekly.resetsAt == now.addingTimeInterval(604_800))
    }

    @Test
    func `general model remains is preferred over video for primary quota`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
          "base_resp": { "status_code": 0 },
          "model_remains": [
            {
              "model_name": "video-v1",
              "current_interval_total_count": 500,
              "current_interval_usage_count": 450
            },
            {
              "model_name": "general",
              "current_interval_total_count": 1000,
              "current_interval_usage_count": 990
            }
          ]
        }
        """
        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8), now: now)
        #expect(snapshot.availablePrompts == 1000)
        #expect(snapshot.currentPrompts == 10)
        #expect(snapshot.remainingPrompts == 990)
        #expect(snapshot.usedPercent == 1)
        let primary = snapshot.toUsageSnapshot().primary
        #expect(primary?.usedPercent == 1)
    }

    @Test
    func `token plan credit parses and api key is ignored`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
          "base_resp": { "status_code": 0 },
          "model_remains": [{ "model_name": "general", "current_interval_remaining_percent": 100 }],
          "token_plan_credit": {
            "total": 1000,
            "used": 230,
            "remaining": 770,
            "api_key": "sk-cp-REDACTED"
          }
        }
        """
        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8), now: now)
        let credits = try #require(snapshot.services?.first(where: { $0.serviceType == "credits" }))
        #expect(credits.limit == 1000)
        #expect(credits.usage == 230)
        #expect(credits.remaining == 770)
    }

    @Test
    func `cycle resource package parses token plan plus metadata`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let end = 1_770_000_000_000
        let json = """
        {
          "base_resp": { "status_code": 0 },
          "model_remains": [{ "model_name": "general", "current_interval_remaining_percent": 100 }],
          "cycle_resource_package": {
            "title": "TokenPlanPlus-月度会员",
            "tier": "Plus",
            "end_time": \(end),
            "credit_total": 28888
          }
        }
        """
        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8), now: now)
        #expect(snapshot.planName == "TokenPlanPlus-月度会员")
        #expect(snapshot.planTier == "Plus")
        #expect(snapshot.planExpiresAt == Date(timeIntervalSince1970: TimeInterval(end) / 1000))
        #expect(snapshot.creditTotal == 28888)
    }

    @Test
    func `cycle resource package title is preferred over generic subscribe title`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
          "base_resp": { "status_code": 0 },
          "current_subscribe_title": "Tag",
          "model_remains": [{ "model_name": "general", "current_interval_remaining_percent": 100 }],
          "cycle_resource_package": {
            "title": "TokenPlanPlus-月度会员",
            "tier": "Plus"
          }
        }
        """
        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8), now: now)
        #expect(snapshot.planName == "TokenPlanPlus-月度会员")
        #expect(snapshot.planTier == "Plus")
    }

    @Test
    func `missing model name still produces text generation service windows`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
          "base_resp": { "status_code": 0 },
          "model_remains": [
            {
              "current_interval_remaining_percent": 99,
              "current_weekly_remaining_percent": 99,
              "remains_time": 240000,
              "weekly_remains_time": 604800000
            }
          ]
        }
        """
        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8), now: now)
        let services = try #require(snapshot.services)
        let fiveHour = try #require(services.first(where: { $0.windowType == "Unknown" }))
        let weekly = try #require(services.first(where: { $0.windowType == "Weekly" }))
        #expect(fiveHour.serviceType == "Text Generation")
        #expect(weekly.serviceType == "Text Generation")
        #expect(fiveHour.percent == 1)
        #expect(weekly.percent == 1)
    }
}
