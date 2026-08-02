import Foundation

/// Reads GitHub Copilot CLI's local session history as a thin parser over the shared aggregation
/// engine.
///
/// Copilot stores one directory per session under `~/.copilot/session-state/<uuid>/events.jsonl`.
/// Unlike most tools it does not log per-request token rows; instead the terminal
/// `session.shutdown` event carries a per-model rollup under `data.modelMetrics.<model>.usage`
/// with `inputTokens`, `outputTokens`, `cacheReadTokens`, `cacheWriteTokens`, and
/// `reasoningTokens`. This scanner reads that rollup (falling back to the last event that carries
/// `modelMetrics` for sessions still in progress) and maps each model bucket to a
/// `UnifiedUsageEvent`, anchoring the day on the event `timestamp`.
///
/// Cached-prefix handling (Copilot's `inputTokens` includes the cached prefix, and there is no
/// separate total, so the engine subtracts it), models.dev pricing, day bucketing, and snapshot
/// construction are all handled once by `UsageEventAggregator`.
public enum CopilotSessionScanner {
    public static let homeEnvironmentKey = "COPILOT_HOME"
    public static let defaultHistoryDays = 30
    public static let maximumFiles = 20000
    public static let maximumBytes = 512 * 1024 * 1024

    private struct WireEvent: Decodable {
        struct ModelUsage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheReadTokens: Int?
            let cacheWriteTokens: Int?
            let reasoningTokens: Int?
        }

        struct ModelBucket: Decodable {
            struct Requests: Decodable {
                let count: Int?
            }

            let usage: ModelUsage?
            let requests: Requests?
        }

        struct Data: Decodable {
            let modelMetrics: [String: ModelBucket]?
        }

        let type: String?
        let timestamp: String?
        let data: Data?
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
        let root = self.homeURL(environment: environment)
            .appendingPathComponent("session-state", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else {
            return nil
        }

        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        let decoder = JSONDecoder()
        let iso8601Fractional = ISO8601DateFormatter()
        iso8601Fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso8601 = ISO8601DateFormatter()
        let parseTimestamp: (String) -> Date? = { raw in
            iso8601Fractional.date(from: raw) ?? iso8601.date(from: raw)
        }

        var events: [UnifiedUsageEvent] = []
        var visitedFiles = 0
        var visitedBytes = 0

        while let url = enumerator.nextObject() as? URL {
            try checkCancellation()
            guard url.pathExtension.lowercased() == "jsonl",
                  url.lastPathComponent == "events.jsonl"
            else {
                continue
            }
            guard visitedFiles < self.maximumFiles else { break }
            let resourceValues = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard resourceValues?.isRegularFile == true else { continue }
            if let modified = resourceValues?.contentModificationDate, modified < start {
                continue
            }
            let size = max(0, resourceValues?.fileSize ?? 0)
            guard size <= self.maximumBytes - visitedBytes else { break }
            visitedFiles += 1
            visitedBytes += size

            do {
                // Keep only the latest event carrying a modelMetrics rollup (the shutdown summary,
                // or the most recent in-progress snapshot), then fold each model bucket once.
                var latest: WireEvent?
                try CostUsageJsonl.scan(
                    fileURL: url,
                    maxLineBytes: 1024 * 1024,
                    prefixBytes: 1024 * 1024,
                    checkCancellation: checkCancellation)
                { line in
                    guard !line.wasTruncated,
                          let event = try? decoder.decode(WireEvent.self, from: line.bytes),
                          let metrics = event.data?.modelMetrics,
                          !metrics.isEmpty
                    else {
                        return
                    }
                    latest = event
                }

                guard let event = latest, let metrics = event.data?.modelMetrics else { continue }
                let eventDate = event.timestamp.flatMap(parseTimestamp)
                    ?? resourceValues?.contentModificationDate
                    ?? now
                let eventDay = calendar.startOfDay(for: eventDate)
                guard eventDay >= start, eventDay <= end else { continue }
                let dayKey = CostUsageLocalDay.key(from: eventDay, calendar: calendar)
                for (rawModel, bucket) in metrics {
                    guard let usage = bucket.usage else { continue }
                    let model = Self.normalizeModel(rawModel)
                    events.append(UnifiedUsageEvent(
                        day: dayKey,
                        model: model,
                        billingProviderID: Self.billingProvider(for: model),
                        inputTokens: usage.inputTokens,
                        outputTokens: usage.outputTokens,
                        totalTokens: nil,
                        cacheReadTokens: usage.cacheReadTokens,
                        cacheCreationTokens: usage.cacheWriteTokens,
                        reasoningTokens: usage.reasoningTokens,
                        requestCount: bucket.requests?.count,
                        pricingProviderIDs: Self.pricingProviderIDs(for: model)))
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
            options: .init(historyLabel: "GitHub Copilot", modelsDevCacheRoot: modelsDevCacheRoot))
    }

    public static func homeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let override = environment[self.homeEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot", isDirectory: true)
    }

    /// Vendor used *only* to look up the rate for a model. Copilot is a harness with no explicit
    /// billing-provider field on its local events, so the model name is the only rate evidence:
    /// a Claude model is priced at Anthropic's rate, a GPT model at OpenAI's, and so on. This
    /// never changes ownership — the usage stays attributed to Copilot (see `billingProvider`).
    private static func pricingProviderIDs(for model: String) -> [String] {
        if model.hasPrefix("claude-") { return ["anthropic"] }
        if model.hasPrefix("gpt-") || model.hasPrefix("o1") || model.hasPrefix("o3") || model.hasPrefix("o4") {
            return ["openai"]
        }
        if model.hasPrefix("gemini-") { return ["google"] }
        return []
    }

    /// Billing ownership always stays with Copilot. The local Copilot event carries no explicit
    /// routing or billing-provider field, so attributing a `claude-*`/`gpt-*`/`gemini-*` model to
    /// another provider would mix Copilot activity into that provider's rows based only on a name.
    /// The vendor is used solely as the rate-lookup key in `pricingProviderIDs`.
    private static func billingProvider(for _: String) -> String? {
        UsageProvider.copilot.rawValue
    }

    /// Normalizes Copilot's model ids to the pricing keys used by the built-in tables and
    /// models.dev (e.g. `claude-haiku-4.5` -> `claude-haiku-4-5`).
    private static func normalizeModel(_ raw: String) -> String {
        var model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty { return "unknown" }
        // Version separators in Claude ids are dots in Copilot but dashes in the pricing tables.
        if model.hasPrefix("claude-") {
            model = model.replacingOccurrences(of: ".", with: "-")
        }
        return model
    }
}
