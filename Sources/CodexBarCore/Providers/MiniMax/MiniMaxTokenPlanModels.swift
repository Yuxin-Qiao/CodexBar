import Foundation

struct MiniMaxCodingPlanData: Decodable {
    let baseResp: MiniMaxBaseResponse?
    let currentSubscribeTitle: String?
    let planName: String?
    let comboTitle: String?
    let currentPlanTitle: String?
    let currentComboCard: MiniMaxComboCard?
    let tokenPlanCredit: MiniMaxTokenPlanCredit?
    let cycleResourcePackage: MiniMaxCycleResourcePackage?
    let modelRemains: [MiniMaxModelRemains]

    private enum CodingKeys: String, CodingKey {
        case baseResp = "base_resp"
        case currentSubscribeTitle = "current_subscribe_title"
        case planName = "plan_name"
        case comboTitle = "combo_title"
        case currentPlanTitle = "current_plan_title"
        case currentComboCard = "current_combo_card"
        case tokenPlanCredit = "token_plan_credit"
        case cycleResourcePackage = "cycle_resource_package"
        case modelRemains = "model_remains"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.baseResp = try container.decodeIfPresent(MiniMaxBaseResponse.self, forKey: .baseResp)
        self.currentSubscribeTitle = try container.decodeIfPresent(String.self, forKey: .currentSubscribeTitle)
        self.planName = try container.decodeIfPresent(String.self, forKey: .planName)
        self.comboTitle = try container.decodeIfPresent(String.self, forKey: .comboTitle)
        self.currentPlanTitle = try container.decodeIfPresent(String.self, forKey: .currentPlanTitle)
        self.currentComboCard = try container.decodeIfPresent(MiniMaxComboCard.self, forKey: .currentComboCard)
        self.tokenPlanCredit = try container.decodeIfPresent(MiniMaxTokenPlanCredit.self, forKey: .tokenPlanCredit)
        self.cycleResourcePackage = try container.decodeIfPresent(
            MiniMaxCycleResourcePackage.self,
            forKey: .cycleResourcePackage)
        self.modelRemains = try (container.decodeIfPresent([MiniMaxModelRemains].self, forKey: .modelRemains)) ?? []
    }
}

struct MiniMaxComboCard: Decodable {
    let title: String?
}

struct MiniMaxModelRemains: Decodable {
    let modelName: String?
    let currentIntervalTotalCount: Int?
    let currentIntervalUsageCount: Int?
    let startTime: Int?
    let endTime: Int?
    let remainsTime: Int?
    let currentIntervalRemainingPercent: Double?
    let currentWeeklyTotalCount: Int?
    let currentWeeklyUsageCount: Int?
    let currentWeeklyRemainingPercent: Double?
    let weeklyStartTime: Int?
    let weeklyEndTime: Int?
    let weeklyRemainsTime: Int?

    private enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case currentIntervalTotalCount = "current_interval_total_count"
        case currentIntervalUsageCount = "current_interval_usage_count"
        case startTime = "start_time"
        case endTime = "end_time"
        case remainsTime = "remains_time"
        case currentIntervalRemainingPercent = "current_interval_remaining_percent"
        case currentWeeklyTotalCount = "current_weekly_total_count"
        case currentWeeklyUsageCount = "current_weekly_usage_count"
        case currentWeeklyRemainingPercent = "current_weekly_remaining_percent"
        case weeklyStartTime = "weekly_start_time"
        case weeklyEndTime = "weekly_end_time"
        case weeklyRemainsTime = "weekly_remains_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        self.currentIntervalTotalCount = MiniMaxDecoding.decodeInt(container, forKey: .currentIntervalTotalCount)
        self.currentIntervalUsageCount = MiniMaxDecoding.decodeInt(container, forKey: .currentIntervalUsageCount)
        self.startTime = MiniMaxDecoding.decodeInt(container, forKey: .startTime)
        self.endTime = MiniMaxDecoding.decodeInt(container, forKey: .endTime)
        self.remainsTime = MiniMaxDecoding.decodeInt(container, forKey: .remainsTime)
        self.currentIntervalRemainingPercent = MiniMaxDecoding.decodeDouble(
            container,
            forKey: .currentIntervalRemainingPercent)
        self.currentWeeklyTotalCount = MiniMaxDecoding.decodeInt(container, forKey: .currentWeeklyTotalCount)
        self.currentWeeklyUsageCount = MiniMaxDecoding.decodeInt(container, forKey: .currentWeeklyUsageCount)
        self.currentWeeklyRemainingPercent = MiniMaxDecoding.decodeDouble(
            container,
            forKey: .currentWeeklyRemainingPercent)
        self.weeklyStartTime = MiniMaxDecoding.decodeInt(container, forKey: .weeklyStartTime)
        self.weeklyEndTime = MiniMaxDecoding.decodeInt(container, forKey: .weeklyEndTime)
        self.weeklyRemainsTime = MiniMaxDecoding.decodeInt(container, forKey: .weeklyRemainsTime)
    }
}

struct MiniMaxTokenPlanCredit: Decodable {
    let total: Int?
    let used: Int?
    let remaining: Int?

    private enum CodingKeys: String, CodingKey {
        case total
        case used
        case remaining
        case apiKey = "api_key"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.total = MiniMaxDecoding.decodeInt(container, forKey: .total)
        self.used = MiniMaxDecoding.decodeInt(container, forKey: .used)
        self.remaining = MiniMaxDecoding.decodeInt(container, forKey: .remaining)
        _ = try? container.decodeIfPresent(String.self, forKey: .apiKey) // explicitly ignored
    }
}

struct MiniMaxCycleResourcePackage: Decodable {
    let title: String?
    let tier: String?
    let expiresAt: Date?
    let creditTotal: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.title = Self.decodeString(container, keys: ["title", "plan_title", "plan_name", "summary"])
        self.tier = Self.decodeString(container, keys: ["tier", "plan_tier", "level"])
        self.creditTotal = Self.decodeInt(container, keys: ["credit_total", "total_credit", "total_credits"])
        self.expiresAt = Self.decodeDate(
            container,
            keys: ["end_time", "end_ts", "expire_time", "expires_at", "end_date"])
    }

    private static func decodeString(_ container: KeyedDecodingContainer<DynamicCodingKey>, keys: [String]) -> String? {
        for key in keys {
            guard let codingKey = DynamicCodingKey(stringValue: key) else { continue }
            if let value = try? container.decodeIfPresent(String.self, forKey: codingKey),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return value
            }
        }
        return nil
    }

    private static func decodeInt(_ container: KeyedDecodingContainer<DynamicCodingKey>, keys: [String]) -> Int? {
        for key in keys {
            guard let codingKey = DynamicCodingKey(stringValue: key) else { continue }
            if let value = MiniMaxDecoding.decodeInt(container, forKey: codingKey) {
                return value
            }
        }
        return nil
    }

    private static func decodeDate(_ container: KeyedDecodingContainer<DynamicCodingKey>, keys: [String]) -> Date? {
        for key in keys {
            guard let codingKey = DynamicCodingKey(stringValue: key) else { continue }
            if let string = try? container.decodeIfPresent(String.self, forKey: codingKey) {
                if let parsed = Self.parseDate(string) { return parsed }
            }
            if let intValue = MiniMaxDecoding.decodeInt(container, forKey: codingKey),
               let parsed = Self.dateFromFlexibleEpoch(intValue)
            {
                return parsed
            }
        }
        return nil
    }

    private static func parseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let intValue = Int(trimmed), let date = Self.dateFromFlexibleEpoch(intValue) {
            return date
        }
        let formats = ["yyyy-MM-dd", "yyyy/MM/dd", "yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return ISO8601DateFormatter().date(from: trimmed)
    }

    private static func dateFromFlexibleEpoch(_ raw: Int) -> Date? {
        if raw > 1_000_000_000_000 { return Date(timeIntervalSince1970: TimeInterval(raw) / 1000) }
        if raw > 1_000_000_000 { return Date(timeIntervalSince1970: TimeInterval(raw)) }
        return nil
    }
}

struct MiniMaxBaseResponse: Decodable {
    let statusCode: Int?
    let statusMessage: String?

    private enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case statusMessage = "status_msg"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.statusCode = MiniMaxDecoding.decodeInt(container, forKey: .statusCode)
        self.statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}
