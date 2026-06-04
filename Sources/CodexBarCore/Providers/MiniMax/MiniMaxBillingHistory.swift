import Foundation

public struct MiniMaxBillingSummary: Sendable {
    public let todayTokens: Int
    public let last7DaysTokens: Int?
    public let last30DaysTokens: Int
    public let todayCash: Double?
    public let last30DaysCash: Double?
    public let daily: [MiniMaxBillingDay]
    public let topMethods: [MiniMaxBillingBreakdown]
    public let topModels: [MiniMaxBillingBreakdown]
    public let updatedAt: Date

    public init(
        todayTokens: Int,
        last7DaysTokens: Int? = nil,
        last30DaysTokens: Int,
        todayCash: Double?,
        last30DaysCash: Double?,
        daily: [MiniMaxBillingDay],
        topMethods: [MiniMaxBillingBreakdown],
        topModels: [MiniMaxBillingBreakdown],
        updatedAt: Date)
    {
        self.todayTokens = todayTokens
        self.last7DaysTokens = last7DaysTokens
        self.last30DaysTokens = last30DaysTokens
        self.todayCash = todayCash
        self.last30DaysCash = last30DaysCash
        self.daily = daily
        self.topMethods = topMethods
        self.topModels = topModels
        self.updatedAt = updatedAt
    }
}

public struct MiniMaxBillingDay: Sendable, Equatable {
    public let day: String
    public let tokens: Int
    public let cash: Double?

    public init(day: String, tokens: Int, cash: Double?) {
        self.day = day
        self.tokens = tokens
        self.cash = cash
    }
}

public struct MiniMaxBillingBreakdown: Sendable, Equatable {
    public let name: String
    public let tokens: Int
    public let cash: Double?

    public init(name: String, tokens: Int, cash: Double?) {
        self.name = name
        self.tokens = tokens
        self.cash = cash
    }
}

struct MiniMaxBillingHistoryPayload: Decodable {
    let baseResp: MiniMaxBaseResponse?
    let chargeRecords: [MiniMaxBillingRecord]
    let totalCount: Int?

    private enum CodingKeys: String, CodingKey {
        case baseResp = "base_resp"
        case chargeRecords = "charge_records"
        case totalCount = "total_cnt"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.baseResp = try container.decodeIfPresent(MiniMaxBaseResponse.self, forKey: .baseResp)
        self.chargeRecords = try container.decodeIfPresent([MiniMaxBillingRecord].self, forKey: .chargeRecords) ?? []
        self.totalCount = MiniMaxDecoding.decodeInt(container, forKey: .totalCount)
    }
}

struct MiniMaxTokenPlanUsageSummaryPayload: Decodable {
    let baseResp: MiniMaxBaseResponse?
    let totalDays: Int?
    let totalTokenConsumed: String?
    let mostActiveDay: MiniMaxTokenPlanMostActiveDay?
    let activeDays: Int?
    let dailyTokenUsage: [Int]

    private enum CodingKeys: String, CodingKey {
        case baseResp = "base_resp"
        case totalDays = "total_days"
        case totalTokenConsumed = "total_token_consumed"
        case mostActiveDay = "most_active_day"
        case activeDays = "active_days"
        case dailyTokenUsage = "daily_token_usage"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.baseResp = try container.decodeIfPresent(MiniMaxBaseResponse.self, forKey: .baseResp)
        self.totalDays = MiniMaxDecoding.decodeInt(container, forKey: .totalDays)
        self.totalTokenConsumed = try container.decodeIfPresent(String.self, forKey: .totalTokenConsumed)
        self.mostActiveDay = try container.decodeIfPresent(MiniMaxTokenPlanMostActiveDay.self, forKey: .mostActiveDay)
        self.activeDays = MiniMaxDecoding.decodeInt(container, forKey: .activeDays)
        self.dailyTokenUsage = try container.decodeIfPresent([MiniMaxFlexibleInt].self, forKey: .dailyTokenUsage)?
            .map(\.value) ?? []
    }
}

struct MiniMaxTokenPlanMostActiveDay: Decodable {
    let date: String?
    let tokenCount: String?

    private enum CodingKeys: String, CodingKey {
        case date
        case tokenCount = "token_count"
    }
}

private struct MiniMaxFlexibleInt: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let string = try? container.decode(String.self),
                  let int = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            self.value = int
        } else {
            self.value = 0
        }
    }
}

struct MiniMaxBillingRecord: Decodable {
    let consumeToken: Int?
    let consumeInputToken: Int?
    let consumeOutputToken: Int?
    let consumeCash: Double?
    let consumeCashAfterVoucher: Double?
    let createdAt: Int?
    let ymd: String?
    let consumeTime: String?
    let method: String?
    let model: String?
    let result: String?
    let status: String?

    private enum CodingKeys: String, CodingKey {
        case consumeToken = "consume_token"
        case consumeInputToken = "consume_input_token"
        case consumeOutputToken = "consume_output_token"
        case consumeCash = "consume_cash"
        case consumeCashAfterVoucher = "consume_cash_after_voucher"
        case createdAt = "created_at"
        case ymd
        case consumeTime = "consume_time"
        case method
        case model
        case result
        case status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.consumeToken = MiniMaxDecoding.decodeInt(container, forKey: .consumeToken)
        self.consumeInputToken = MiniMaxDecoding.decodeInt(container, forKey: .consumeInputToken)
        self.consumeOutputToken = MiniMaxDecoding.decodeInt(container, forKey: .consumeOutputToken)
        self.consumeCash = MiniMaxDecoding.decodeDouble(container, forKey: .consumeCash)
        self.consumeCashAfterVoucher = MiniMaxDecoding.decodeDouble(container, forKey: .consumeCashAfterVoucher)
        self.createdAt = MiniMaxDecoding.decodeInt(container, forKey: .createdAt)
        self.ymd = try container.decodeIfPresent(String.self, forKey: .ymd)
        self.consumeTime = try container.decodeIfPresent(String.self, forKey: .consumeTime)
        self.method = try container.decodeIfPresent(String.self, forKey: .method)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.result = Self.decodeOptionalScalarString(container, forKey: .result)
        self.status = Self.decodeOptionalScalarString(container, forKey: .status)
    }

    var recordResult: String? {
        if let result = self.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
            return result
        }
        if let status = self.status?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty {
            return status
        }
        return nil
    }

    var tokenCount: Int {
        if let consumeToken, consumeToken > 0 { return consumeToken }
        return max(0, (self.consumeInputToken ?? 0) + (self.consumeOutputToken ?? 0))
    }

    var cashValue: Double? {
        self.consumeCashAfterVoucher ?? self.consumeCash
    }

    private static func decodeOptionalScalarString<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        forKey key: K) -> String?
    {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return String(value)
        }
        return nil
    }
}

enum MiniMaxBillingHistoryParser {
    static func decodePayload(data: Data) throws -> MiniMaxBillingHistoryPayload {
        try JSONDecoder().decode(MiniMaxBillingHistoryPayload.self, from: data)
    }

    static func decodeUsageSummaryPayload(data: Data) throws -> MiniMaxTokenPlanUsageSummaryPayload {
        try JSONDecoder().decode(MiniMaxTokenPlanUsageSummaryPayload.self, from: data)
    }

    static func parseUsageSummary(
        data: Data,
        now: Date = Date(),
        calendar: Calendar = .current) throws -> MiniMaxBillingSummary
    {
        let payload = try self.decodeUsageSummaryPayload(data: data)
        if let status = payload.baseResp?.statusCode, status != 0 {
            let message = payload.baseResp?.statusMessage ?? "status_code \(status)"
            if status == 1004 || status == 401 || status == 403 {
                throw MiniMaxUsageError.invalidCredentials
            }
            throw MiniMaxUsageError.apiError(message)
        }
        guard !payload.dailyTokenUsage.isEmpty else {
            throw MiniMaxUsageError.parseFailed("Missing MiniMax token plan usage summary.")
        }
        return self.aggregateUsageSummary(payload: payload, now: now, calendar: calendar)
    }

    static func aggregateUsageSummary(
        payload: MiniMaxTokenPlanUsageSummaryPayload,
        now: Date = Date(),
        calendar inputCalendar: Calendar = .current) -> MiniMaxBillingSummary
    {
        var calendar = inputCalendar
        calendar.timeZone = inputCalendar.timeZone

        let usage = payload.dailyTokenUsage.map { max(0, $0) }
        let reportedDays = max(0, payload.totalDays ?? usage.count)
        let relevantUsage = reportedDays > 0 ? Array(usage.suffix(reportedDays)) : usage
        let latestDay = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
            ?? calendar.startOfDay(for: now)
        let startOffset = relevantUsage.count - 1
        let daily = relevantUsage.enumerated().compactMap { index, tokens -> MiniMaxBillingDay? in
            guard let date = calendar.date(byAdding: .day, value: index - startOffset, to: latestDay) else {
                return nil
            }
            return MiniMaxBillingDay(day: self.dayString(date, calendar: calendar), tokens: tokens, cash: nil)
        }

        let latestTokens = relevantUsage.last ?? 0
        let last7Tokens = relevantUsage.suffix(7).reduce(0, +)
        let last30Tokens = relevantUsage.suffix(30).reduce(0, +)
        let topModels = self.usageSummaryTopModels(payload: payload, daily: daily)

        return MiniMaxBillingSummary(
            todayTokens: latestTokens,
            last7DaysTokens: last7Tokens,
            last30DaysTokens: last30Tokens,
            todayCash: nil,
            last30DaysCash: nil,
            daily: daily,
            topMethods: [],
            topModels: topModels,
            updatedAt: now)
    }

    static func parse(
        data: Data,
        now: Date = Date(),
        calendar: Calendar = .current) throws -> MiniMaxBillingSummary
    {
        let payload = try self.decodePayload(data: data)
        if let status = payload.baseResp?.statusCode, status != 0 {
            let message = payload.baseResp?.statusMessage ?? "status_code \(status)"
            throw MiniMaxUsageError.apiError(message)
        }
        guard !payload.chargeRecords.isEmpty || (payload.totalCount ?? 0) == 0 else {
            throw MiniMaxUsageError.parseFailed("Missing MiniMax billing records.")
        }
        return self.aggregate(records: payload.chargeRecords, now: now, calendar: calendar)
    }

    static func aggregate(
        records: [MiniMaxBillingRecord],
        now: Date = Date(),
        calendar inputCalendar: Calendar = .current) -> MiniMaxBillingSummary
    {
        var calendar = inputCalendar
        calendar.timeZone = inputCalendar.timeZone

        let startOfToday = calendar.startOfDay(for: now)
        let startOf30Days = calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
        var daily: [String: (date: Date, tokens: Int, cash: Double, hasCash: Bool)] = [:]
        var methodTotals: [String: (tokens: Int, cash: Double, hasCash: Bool)] = [:]
        var modelTotals: [String: (tokens: Int, cash: Double, hasCash: Bool)] = [:]

        for record in records {
            if let recordResult = record.recordResult,
               recordResult.caseInsensitiveCompare("SUCCESS") != .orderedSame
            {
                continue
            }

            guard let date = self.recordDate(record, calendar: calendar),
                  date >= startOf30Days,
                  date <= now
            else {
                continue
            }

            let day = self.dayString(date, calendar: calendar)
            let tokens = record.tokenCount
            let cash = record.cashValue
            var bucket = daily[day] ?? (calendar.startOfDay(for: date), 0, 0, false)
            bucket.tokens += tokens
            if let cash {
                bucket.cash += cash
                bucket.hasCash = true
            }
            daily[day] = bucket

            self.add(record, tokens: tokens, cash: cash, keyPath: \.method, totals: &methodTotals)
            self.add(record, tokens: tokens, cash: cash, keyPath: \.model, totals: &modelTotals)
        }

        let sortedDays = daily
            .sorted { $0.value.date < $1.value.date }
            .map { key, value in
                MiniMaxBillingDay(
                    day: key,
                    tokens: value.tokens,
                    cash: value.hasCash ? value.cash : nil)
            }
        let todayKey = self.dayString(now, calendar: calendar)
        let today = daily[todayKey]
        let startOf7Days = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        let last7Tokens = sortedDays.reduce(0) { total, day in
            guard let date = self.parseDateOnly(day.day, calendar: calendar), date >= startOf7Days else {
                return total
            }
            return total + day.tokens
        }
        let last30Tokens = sortedDays.reduce(0) { $0 + $1.tokens }
        let last30CashValues = sortedDays.compactMap(\.cash)
        let last30Cash = last30CashValues.isEmpty ? nil : last30CashValues.reduce(0, +)

        return MiniMaxBillingSummary(
            todayTokens: today?.tokens ?? 0,
            last7DaysTokens: last7Tokens,
            last30DaysTokens: last30Tokens,
            todayCash: (today?.hasCash == true) ? today?.cash : nil,
            last30DaysCash: last30Cash,
            daily: sortedDays,
            topMethods: self.breakdowns(from: methodTotals),
            topModels: self.breakdowns(from: modelTotals),
            updatedAt: now)
    }

    private static func add(
        _ record: MiniMaxBillingRecord,
        tokens: Int,
        cash: Double?,
        keyPath: KeyPath<MiniMaxBillingRecord, String?>,
        totals: inout [String: (tokens: Int, cash: Double, hasCash: Bool)])
    {
        let rawName = record[keyPath: keyPath]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawName, !rawName.isEmpty else { return }
        var total = totals[rawName] ?? (0, 0, false)
        total.tokens += tokens
        if let cash {
            total.cash += cash
            total.hasCash = true
        }
        totals[rawName] = total
    }

    private static func breakdowns(from totals: [String: (tokens: Int, cash: Double, hasCash: Bool)])
        -> [MiniMaxBillingBreakdown]
    {
        totals
            .map { name, value in
                MiniMaxBillingBreakdown(
                    name: name,
                    tokens: value.tokens,
                    cash: value.hasCash ? value.cash : nil)
            }
            .sorted {
                if $0.tokens == $1.tokens {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.tokens > $1.tokens
            }
            .prefix(3)
            .map(\.self)
    }

    private static func usageSummaryTopModels(
        payload: MiniMaxTokenPlanUsageSummaryPayload,
        daily: [MiniMaxBillingDay]) -> [MiniMaxBillingBreakdown]
    {
        guard let mostActive = payload.mostActiveDay,
              let date = mostActive.date?.trimmingCharacters(in: .whitespacesAndNewlines),
              !date.isEmpty
        else {
            return []
        }
        let tokens = self.tokenCount(from: mostActive.tokenCount)
            ?? daily.first(where: { $0.day == date })?.tokens
            ?? daily.map(\.tokens).max()
            ?? 0
        guard tokens > 0 else { return [] }
        return [MiniMaxBillingBreakdown(name: "Peak \(date)", tokens: tokens, cash: nil)]
    }

    private static func tokenCount(from value: String?) -> Int? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        let uppercased = value.uppercased()
        let multiplier: Double
        let numeric: String
        if uppercased.hasSuffix("B") {
            multiplier = 1_000_000_000
            numeric = String(uppercased.dropLast())
        } else if uppercased.hasSuffix("M") {
            multiplier = 1_000_000
            numeric = String(uppercased.dropLast())
        } else if uppercased.hasSuffix("K") {
            multiplier = 1_000
            numeric = String(uppercased.dropLast())
        } else {
            multiplier = 1
            numeric = uppercased
        }
        guard let number = Double(numeric) else { return nil }
        return Int((number * multiplier).rounded())
    }

    static func containsRecordBefore30DayWindow(
        _ records: [MiniMaxBillingRecord],
        now: Date = Date(),
        calendar inputCalendar: Calendar = .current) -> Bool
    {
        var calendar = inputCalendar
        calendar.timeZone = inputCalendar.timeZone
        let startOfToday = calendar.startOfDay(for: now)
        let startOf30Days = calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
        return records.contains { record in
            guard let date = self.recordDate(record, calendar: calendar) else { return false }
            return date < startOf30Days
        }
    }

    private static func recordDate(_ record: MiniMaxBillingRecord, calendar: Calendar) -> Date? {
        if let createdAt = record.createdAt {
            let interval = createdAt > 1_000_000_000_000
                ? TimeInterval(createdAt) / 1000
                : TimeInterval(createdAt)
            return Date(timeIntervalSince1970: interval)
        }
        if let ymd = record.ymd {
            return self.parseDateOnly(ymd, calendar: calendar)
        }
        if let consumeTime = record.consumeTime {
            return self.parseDate(consumeTime, formats: [
                "yyyy-MM-dd HH:mm:ss",
                "yyyy/MM/dd HH:mm:ss",
                "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            ])
        }
        return nil
    }

    private static func parseDateOnly(_ text: String, calendar: Calendar) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        for format in ["yyyy-MM-dd", "yyyyMMdd", "yyyy/MM/dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return calendar.startOfDay(for: date)
            }
        }
        return nil
    }

    private static func parseDate(_ text: String, formats: [String]) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day
        else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
