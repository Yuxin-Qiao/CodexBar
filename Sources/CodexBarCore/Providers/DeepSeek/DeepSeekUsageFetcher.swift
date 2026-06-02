import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - API response types

public struct DeepSeekBalanceResponse: Decodable, Sendable {
    public let isAvailable: Bool
    public let balanceInfos: [DeepSeekBalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

public struct DeepSeekBalanceInfo: Decodable, Sendable {
    public let currency: String
    public let totalBalance: String
    public let grantedBalance: String
    public let toppedUpBalance: String

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case grantedBalance = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }
}

// MARK: - Domain snapshot

public struct DeepSeekUsageSnapshot: Sendable {
    public let isAvailable: Bool
    public let currency: String
    public let totalBalance: Double
    public let grantedBalance: Double
    public let toppedUpBalance: Double
    public let usageSummary: DeepSeekUsageSummary?
    /// Why the optional usage summary could not be populated. `nil` when the
    /// summary either succeeded or was not requested. Set when the summary
    /// fetch threw (e.g. the platform endpoints require a web session cookie
    /// the API key cannot satisfy); the UI should surface a hint instead of
    /// silently hiding the dashboard.
    public let summaryFailure: DeepSeekUsageError?
    public let updatedAt: Date

    public init(
        isAvailable: Bool,
        currency: String,
        totalBalance: Double,
        grantedBalance: Double,
        toppedUpBalance: Double,
        usageSummary: DeepSeekUsageSummary? = nil,
        summaryFailure: DeepSeekUsageError? = nil,
        updatedAt: Date)
    {
        self.isAvailable = isAvailable
        self.currency = currency
        self.totalBalance = totalBalance
        self.grantedBalance = grantedBalance
        self.toppedUpBalance = toppedUpBalance
        self.usageSummary = usageSummary
        self.summaryFailure = summaryFailure
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let symbol = self.currency == "CNY" ? "¥" : "$"

        let balanceDetail: String
        let usedPercent: Double
        if self.totalBalance <= 0 {
            balanceDetail = "\(symbol)0.00 — add credits at platform.deepseek.com"
            usedPercent = 100
        } else if !self.isAvailable {
            balanceDetail = "Balance unavailable for API calls"
            usedPercent = 100
        } else {
            let total = String(format: "\(symbol)%.2f", self.totalBalance)
            let paid = String(format: "\(symbol)%.2f", self.toppedUpBalance)
            let granted = String(format: "\(symbol)%.2f", self.grantedBalance)
            balanceDetail = "\(total) (Paid: \(paid) / Granted: \(granted))"
            usedPercent = 0
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .deepseek,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)
        let balanceWindow = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: balanceDetail)

        return UsageSnapshot(
            primary: balanceWindow,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            deepseekUsage: self.usageSummary,
            deepseekSummaryError: self.summaryFailure,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

// MARK: - Errors

public enum DeepSeekUsageError: LocalizedError, Sendable {
    case missingCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)
    /// The platform.deepseek.com usage endpoints require a web session cookie,
    /// not an API key. Raised when the server returns 200 OK with an
    /// application-level auth error code (e.g. 40003 "invalid token").
    case sessionCookieRequired(endpoint: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing DeepSeek API key."
        case let .networkError(message):
            "DeepSeek network error: \(message)"
        case let .apiError(message):
            "DeepSeek API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse DeepSeek response: \(message)"
        case let .sessionCookieRequired(endpoint, message):
            "DeepSeek \(endpoint) needs a web session: \(message)"
        }
    }

    /// Whether this error means the user's API key works for balance but
    /// the platform usage endpoints require a separate authentication path.
    public var isSessionCookieRequired: Bool {
        if case .sessionCookieRequired = self { return true }
        return false
    }

    /// Short, user-facing hint to surface in the menu when the optional
    /// usage dashboard cannot be loaded. `nil` for errors that the UI
    /// should not advertise to end users (e.g. `.missingCredentials` is
    /// already shown by the provider pane).
    public var userHint: String? {
        switch self {
        case .sessionCookieRequired:
            "Sign in to platform.deepseek.com to enable usage stats."
        case .networkError, .apiError:
            "DeepSeek usage stats temporarily unavailable."
        case .parseFailed:
            "DeepSeek usage stats unavailable — server response changed."
        case .missingCredentials:
            nil
        }
    }
}

// MARK: - Fetcher

public struct DeepSeekUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.deepSeekUsage)
    private static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!
    private static let usageAmountURL = URL(string: "https://platform.deepseek.com/api/v0/usage/amount")!
    private static let usageCostURL = URL(string: "https://platform.deepseek.com/api/v0/usage/cost")!
    private static let timeoutSeconds: TimeInterval = 15
    private static let optionalSummaryJoinGrace: Duration = .seconds(2)
    private static var apiCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    public static func fetchUsage(
        apiKey: String,
        includeOptionalUsage: Bool = true) async throws -> DeepSeekUsageSnapshot
    {
        try await self.fetchUsage(
            apiKey: apiKey,
            includeOptionalUsage: includeOptionalUsage,
            optionalSummaryJoinGrace: self.optionalSummaryJoinGrace,
            fetchBalanceData: { key in
                try await self.fetchBalanceData(apiKey: key)
            },
            fetchSummary: { key in
                try await self.fetchUsageSummary(apiKey: key)
            })
    }

    static func _fetchUsageForTesting(
        apiKey: String,
        includeOptionalUsage: Bool,
        optionalSummaryJoinGrace: Duration = .zero,
        fetchBalanceData: @escaping @Sendable (String) async throws -> Data,
        fetchSummary: @escaping @Sendable (String) async throws -> DeepSeekUsageSummary)
        async throws -> DeepSeekUsageSnapshot
    {
        try await self.fetchUsage(
            apiKey: apiKey,
            includeOptionalUsage: includeOptionalUsage,
            optionalSummaryJoinGrace: optionalSummaryJoinGrace,
            fetchBalanceData: fetchBalanceData,
            fetchSummary: fetchSummary)
    }

    private static func fetchUsage(
        apiKey: String,
        includeOptionalUsage: Bool,
        optionalSummaryJoinGrace: Duration,
        fetchBalanceData: @escaping @Sendable (String) async throws -> Data,
        fetchSummary: @escaping @Sendable (String) async throws -> DeepSeekUsageSummary)
        async throws -> DeepSeekUsageSnapshot
    {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeepSeekUsageError.missingCredentials
        }

        let summaryTask: Task<DeepSeekUsageSummary, Error>? = if includeOptionalUsage {
            Task {
                try await fetchSummary(apiKey)
            }
        } else {
            nil
        }

        let balanceData: Data
        do {
            balanceData = try await fetchBalanceData(apiKey)
        } catch {
            summaryTask?.cancel()
            throw error
        }
        var snapshot: DeepSeekUsageSnapshot
        do {
            snapshot = try Self.parseSnapshot(data: balanceData)
        } catch {
            summaryTask?.cancel()
            throw error
        }

        if let summaryTask {
            let (summary, failure) = try await self.completedOptionalUsageSummary(
                from: summaryTask,
                joinGrace: optionalSummaryJoinGrace)
            if let summary {
                snapshot = DeepSeekUsageSnapshot(
                    isAvailable: snapshot.isAvailable,
                    currency: snapshot.currency,
                    totalBalance: snapshot.totalBalance,
                    grantedBalance: snapshot.grantedBalance,
                    toppedUpBalance: snapshot.toppedUpBalance,
                    usageSummary: summary,
                    summaryFailure: nil,
                    updatedAt: snapshot.updatedAt)
            } else if let failure {
                snapshot = DeepSeekUsageSnapshot(
                    isAvailable: snapshot.isAvailable,
                    currency: snapshot.currency,
                    totalBalance: snapshot.totalBalance,
                    grantedBalance: snapshot.grantedBalance,
                    toppedUpBalance: snapshot.toppedUpBalance,
                    usageSummary: nil,
                    summaryFailure: failure,
                    updatedAt: snapshot.updatedAt)
            }
        }

        return snapshot
    }

    private static func fetchBalanceData(apiKey: String) async throws -> Data {
        var request = URLRequest(url: self.balanceURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        let response = try await ProviderHTTPClient.shared.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            Self.log.error("DeepSeek balance endpoint returned HTTP \(response.statusCode)")
            throw DeepSeekUsageError.apiError("HTTP \(response.statusCode)")
        }

        return data
    }

    private static func completedOptionalUsageSummary(
        from task: Task<DeepSeekUsageSummary, Error>,
        joinGrace: Duration) async throws -> (DeepSeekUsageSummary?, DeepSeekUsageError?)
    {
        try await withTaskCancellationHandler {
            do {
                return try await withThrowingTaskGroup(of: (DeepSeekUsageSummary?, DeepSeekUsageError?).self) { group in
                    group.addTask {
                        do {
                            let summary = try await task.value
                            return (summary, nil)
                        } catch let error as DeepSeekUsageError {
                            return (nil, error)
                        } catch {
                            return (nil, .networkError(error.localizedDescription))
                        }
                    }
                    group.addTask {
                        if joinGrace > .zero {
                            try await Task.sleep(for: joinGrace)
                        }
                        return (nil, nil)
                    }

                    guard let result = try await group.next() else {
                        return (nil, nil)
                    }
                    if result.0 == nil, result.1 == nil {
                        // Grace expired first; cancel the in-flight task.
                        task.cancel()
                    }
                    group.cancelAll()
                    return result
                }
            } catch {
                task.cancel()
                if Task.isCancelled {
                    throw error
                }
                return (nil, .networkError(error.localizedDescription))
            }
        } onCancel: {
            task.cancel()
        }
    }

    static func _parseSnapshotForTesting(_ data: Data) throws -> DeepSeekUsageSnapshot {
        try self.parseSnapshot(data: data)
    }

    public static func fetchUsageSummary(
        apiKey: String,
        now: Date = Date(),
        calendar: Calendar? = nil) async throws -> DeepSeekUsageSummary
    {
        let calendar = calendar ?? self.apiCalendar
        let period = try self.usagePeriod(now: now, calendar: calendar)

        let amountData = try await self.fetchAmount(apiKey: apiKey, month: period.month, year: period.year)
        let costData = try await self.fetchCost(apiKey: apiKey, month: period.month, year: period.year)

        return try DeepSeekUsageCostParser.parse(
            amountData: amountData,
            costData: costData,
            now: now,
            calendar: calendar)
    }

    static func _apiUsagePeriodForTesting(now: Date, calendar: Calendar? = nil) throws -> (month: Int, year: Int) {
        try self.usagePeriod(now: now, calendar: calendar ?? self.apiCalendar)
    }

    private static func usagePeriod(now: Date, calendar: Calendar) throws -> (month: Int, year: Int) {
        let monthComponents = calendar.dateComponents([.month, .year], from: now)
        guard let month = monthComponents.month, let year = monthComponents.year else {
            throw DeepSeekUsageError.parseFailed("Could not determine current month/year")
        }
        return (month: month, year: year)
    }

    private static func fetchAmount(apiKey: String, month: Int, year: Int) async throws -> Data {
        guard var components = URLComponents(url: self.usageAmountURL, resolvingAgainstBaseURL: false) else {
            throw DeepSeekUsageError.networkError("Invalid URL")
        }
        components.queryItems = [
            URLQueryItem(name: "month", value: String(month)),
            URLQueryItem(name: "year", value: String(year)),
        ]
        guard let url = components.url else {
            throw DeepSeekUsageError.networkError("Could not construct URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        let response = try await ProviderHTTPClient.shared.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw DeepSeekUsageError.missingCredentials
            }
            throw DeepSeekUsageError.apiError("HTTP \(response.statusCode)")
        }
        try self.throwIfApplicationError(data: data, endpoint: "amount")

        return data
    }

    private static func fetchCost(apiKey: String, month: Int, year: Int) async throws -> Data {
        guard var components = URLComponents(url: self.usageCostURL, resolvingAgainstBaseURL: false) else {
            throw DeepSeekUsageError.networkError("Invalid URL")
        }
        components.queryItems = [
            URLQueryItem(name: "month", value: String(month)),
            URLQueryItem(name: "year", value: String(year)),
        ]
        guard let url = components.url else {
            throw DeepSeekUsageError.networkError("Could not construct URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        let response = try await ProviderHTTPClient.shared.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw DeepSeekUsageError.missingCredentials
            }
            throw DeepSeekUsageError.apiError("HTTP \(response.statusCode)")
        }
        try self.throwIfApplicationError(data: data, endpoint: "cost")

        return data
    }

    /// platform.deepseek.com returns HTTP 200 with an application-level error
    /// when the bearer token is rejected (e.g. `{"code":40003,"msg":"Authorization
    /// Failed (invalid token)","data":null}`). Inspect the body and surface
    /// a typed error so callers can distinguish "needs session cookie" from
    /// a real network / parse failure.
    static func _throwIfApplicationErrorForTesting(data: Data, endpoint: String) throws {
        try self.throwIfApplicationError(data: data, endpoint: endpoint)
    }

    private static func throwIfApplicationError(data: Data, endpoint: String) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any]
        else {
            // Body is not a top-level object — let the typed parser fail with
            // its own descriptive error.
            return
        }
        // Only treat as app-level error if `code` is present and non-zero.
        // Many success responses (per DeepSeekUsageCostParser fixtures) include
        // `code: 0` explicitly, so absence is also "ok, no app-level error".
        guard let codeRaw = json["code"], let code = codeRaw as? Int, code != 0 else {
            return
        }
        let message = (json["msg"] as? String) ?? "no message"
        // DeepSeek web console uses 40003 for invalid/expired bearer tokens;
        // the platform usage endpoints require a session cookie set by the
        // browser login, which an API key cannot satisfy.
        if code == 40003
            || message.lowercased().contains("invalid token")
            || message.lowercased().contains("authorization failed")
            || message.lowercased().contains("unauthorized")
        {
            Self.log.warning("DeepSeek \(endpoint) rejected API key (code=\(code)): \(message)")
            throw DeepSeekUsageError.sessionCookieRequired(
                endpoint: endpoint,
                message: "Sign in to platform.deepseek.com to enable usage stats (server: \(message))")
        }
        Self.log.error("DeepSeek \(endpoint) app-level error code=\(code): \(message)")
        throw DeepSeekUsageError.apiError("DeepSeek \(endpoint) returned code \(code): \(message)")
    }

    static func _parseUsageSummaryForTesting(
        amountData: Data,
        costData: Data,
        now: Date = Date(),
        calendar: Calendar = .current) throws -> DeepSeekUsageSummary
    {
        try DeepSeekUsageCostParser.parse(
            amountData: amountData,
            costData: costData,
            now: now,
            calendar: calendar)
    }

    private static func parseSnapshot(data: Data) throws -> DeepSeekUsageSnapshot {
        let decoded: DeepSeekBalanceResponse
        do {
            decoded = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data)
        } catch {
            throw DeepSeekUsageError.parseFailed(error.localizedDescription)
        }

        let balances = try decoded.balanceInfos.map(Self.parseBalanceInfo)
        guard !balances.isEmpty else {
            return DeepSeekUsageSnapshot(
                isAvailable: false,
                currency: "USD",
                totalBalance: 0,
                grantedBalance: 0,
                toppedUpBalance: 0,
                updatedAt: Date())
        }

        // Prefer USD when it is funded, but do not hide a positive CNY balance behind
        // an empty USD row returned by the API.
        let selected = balances.first { $0.currency == "USD" && $0.totalBalance > 0 }
            ?? balances.first { $0.totalBalance > 0 }
            ?? balances.first { $0.currency == "USD" }
            ?? balances[0]

        return DeepSeekUsageSnapshot(
            isAvailable: decoded.isAvailable,
            currency: selected.currency,
            totalBalance: selected.totalBalance,
            grantedBalance: selected.grantedBalance,
            toppedUpBalance: selected.toppedUpBalance,
            updatedAt: Date())
    }

    private struct ParsedBalanceInfo {
        let currency: String
        let totalBalance: Double
        let grantedBalance: Double
        let toppedUpBalance: Double
    }

    private static func parseBalanceInfo(_ info: DeepSeekBalanceInfo) throws -> ParsedBalanceInfo {
        guard
            let total = Double(info.totalBalance),
            let granted = Double(info.grantedBalance),
            let toppedUp = Double(info.toppedUpBalance)
        else {
            throw DeepSeekUsageError.parseFailed("Non-numeric balance value in response.")
        }

        return ParsedBalanceInfo(
            currency: info.currency,
            totalBalance: total,
            grantedBalance: granted,
            toppedUpBalance: toppedUp)
    }
}
