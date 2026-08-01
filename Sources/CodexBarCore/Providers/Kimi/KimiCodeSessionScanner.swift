import Foundation

public enum KimiCodeSessionScanner {
    public static let defaultHistoryDays = 30
    public static let maximumFiles = 20000
    public static let maximumBytes = 512 * 1024 * 1024

    private struct WireEvent: Decodable {
        struct Usage: Decodable {
            let inputOther: Int?
            let inputCacheRead: Int?
            let inputCacheCreation: Int?
            let output: Int?
        }

        let type: String
        let time: Double?
        let model: String?
        let usage: Usage?
        let usageScope: String?
    }

    /// Returns the value when it is a valid non-negative token count, or nil otherwise. A
    /// malformed (negative) count rejects the whole record, matching the pre-migration scanner.
    private static func validOrNil(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    private static func estimatedCost(
        model: String,
        usage: WireEvent.Usage,
        pricingDate: Date,
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> Double?
    {
        guard let input = self.validOrNil(usage.inputOther),
              let cacheRead = self.validOrNil(usage.inputCacheRead),
              let cacheCreation = self.validOrNil(usage.inputCacheCreation),
              let output = self.validOrNil(usage.output)
        else {
            return nil
        }
        return CostUsagePricing.claudeCostUSD(
            model: self.pricingModelID(model),
            inputTokens: input,
            cacheReadInputTokens: cacheRead,
            cacheCreationInputTokens: cacheCreation,
            outputTokens: output,
            pricingDate: pricingDate,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot)
    }

    private static func pricingModelID(_ model: String) -> String {
        let bare = model.split(separator: "/", omittingEmptySubsequences: true).last
            .map(String.init) ?? model
        switch bare.lowercased() {
        case "k3", "k3-256k":
            return "kimi-k3"
        default:
            return bare
        }
    }

    public static func scan(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        historyDays: Int = defaultHistoryDays,
        now: Date = Date(),
        calendar: Calendar = .current,
        modelsDevCacheRoot: URL? = nil) -> CostUsageTokenSnapshot?
    {
        try? self.scanCancellable(
            environment: environment,
            fileManager: fileManager,
            historyDays: historyDays,
            now: now,
            calendar: calendar,
            modelsDevCacheRoot: modelsDevCacheRoot)
    }

    public static func scanCancellable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        historyDays: Int = defaultHistoryDays,
        now: Date = Date(),
        calendar: Calendar = .current,
        modelsDevCacheRoot: URL? = nil,
        checkCancellation: @escaping () throws -> Void = {}) throws -> CostUsageTokenSnapshot?
    {
        try checkCancellation()
        let days = max(1, historyDays)
        let calendar = CostUsageLocalDay.gregorianCalendar(preserving: calendar)
        let home = KimiSettingsReader.kimiCodeHomeURL(environment: environment)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else {
            return nil
        }

        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        var events: [UnifiedUsageEvent] = []
        let decoder = JSONDecoder()
        let modelsDevCatalog = CostUsagePricing.modelsDevCatalog(now: now, cacheRoot: modelsDevCacheRoot)
        var visitedFiles = 0
        var visitedBytes = 0

        while let url = enumerator.nextObject() as? URL {
            try checkCancellation()
            guard url.lastPathComponent == "wire.jsonl",
                  url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "agents"
            else {
                continue
            }
            guard visitedFiles < self.maximumFiles else { break }
            let resourceValues = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard resourceValues?.isRegularFile == true else { continue }
            if let modificationDate = resourceValues?.contentModificationDate,
               modificationDate < start
            {
                continue
            }
            let size = max(0, resourceValues?.fileSize ?? 0)
            guard size <= self.maximumBytes - visitedBytes else { break }
            visitedFiles += 1
            visitedBytes += size
            do {
                try CostUsageJsonl.scan(
                    fileURL: url,
                    maxLineBytes: 1024 * 1024,
                    prefixBytes: 1024 * 1024,
                    checkCancellation: checkCancellation)
                { line in
                    guard !line.wasTruncated,
                          let event = try? decoder.decode(WireEvent.self, from: line.bytes),
                          event.type == "usage.record",
                          event.usageScope == nil || event.usageScope == "turn",
                          let time = event.time,
                          time.isFinite,
                          let rawModel = event.model?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !rawModel.isEmpty,
                          let usage = event.usage
                    else {
                        return
                    }
                    let date = Date(timeIntervalSince1970: time / 1000)
                    let day = calendar.startOfDay(for: date)
                    guard day >= start, day <= end else { return }
                    // Kimi's `inputOther` is already uncached. Passing totalTokens as
                    // input+cacheRead+output (cache-write excluded) hits the engine's
                    // "input is already uncached" branch so it is priced as-is. The estimated cost
                    // is resolved here (official Moonshot rate via the third-party lookup, with a
                    // kimi-k3 fallback) and carried as `providerCostUSD` so the engine trusts it;
                    // an unresolvable cost surfaces as an unpriced day, not a partial subtotal.
                    guard let input = Self.validOrNil(usage.inputOther),
                          let cacheRead = Self.validOrNil(usage.inputCacheRead),
                          let cacheCreation = Self.validOrNil(usage.inputCacheCreation),
                          let output = Self.validOrNil(usage.output)
                    else {
                        return
                    }
                    events.append(UnifiedUsageEvent(
                        day: CostUsageLocalDay.key(from: day, calendar: calendar),
                        model: rawModel,
                        billingProviderID: UsageProvider.kimi.rawValue,
                        inputTokens: input,
                        outputTokens: output,
                        totalTokens: input + cacheRead + output,
                        cacheReadTokens: cacheRead,
                        cacheCreationTokens: cacheCreation,
                        providerCostUSD: Self.estimatedCost(
                            model: rawModel,
                            usage: usage,
                            pricingDate: date,
                            modelsDevCatalog: modelsDevCatalog,
                            modelsDevCacheRoot: modelsDevCacheRoot)))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }

        return UsageEventAggregator.aggregate(
            events: events,
            historyDays: days,
            now: now,
            options: .init(
                historyLabel: "Kimi Code CLI",
                defaultBillingProviderID: UsageProvider.kimi.rawValue,
                modelsDevCacheRoot: modelsDevCacheRoot))
    }

}
