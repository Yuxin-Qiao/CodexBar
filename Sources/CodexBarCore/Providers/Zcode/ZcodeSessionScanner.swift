import Foundation

/// Reads ZCode's local JSONL rollout history as a thin parser over the shared aggregation engine.
///
/// ZCode stores one file per session under `~/.zcode/cli/rollout/model-io-sess_*.jsonl`. Each
/// line is a single billable request with `completedAt` (RFC 3339), `model.modelId` (e.g.
/// `GLM-5.2`), `model.providerId` (e.g. `builtin:bigmodel-start-plan`, the Zhipu/BigModel coding
/// plan), and `response.usage` carrying `inputTokens`, `outputTokens`, `totalTokens`,
/// `cacheReadTokens`, and `cacheWriteTokens`.
///
/// This scanner only walks files and maps each request to a `UnifiedUsageEvent`. The cached-prefix
/// double-count (ZCode's `inputTokens` already includes the cached prefix), models.dev pricing at
/// the official Z.ai rate, day bucketing, and snapshot construction are all handled once by
/// `UsageEventAggregator` — nothing here re-implements them.
public enum ZcodeSessionScanner {
    public static let homeEnvironmentKey = "ZCODE_HOME"
    public static let defaultHistoryDays = 30
    public static let maximumFiles = 20000
    public static let maximumBytes = 512 * 1024 * 1024

    private struct WireMessage: Decodable {
        struct Model: Decodable {
            let modelId: String?
            let providerId: String?
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let totalTokens: Int?
            let cacheReadTokens: Int?
            let cacheWriteTokens: Int?
        }

        struct Response: Decodable {
            let usage: Usage?
        }

        let completedAt: String?
        let model: Model?
        let response: Response?
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
            .appendingPathComponent("cli", isDirectory: true)
            .appendingPathComponent("rollout", isDirectory: true)
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
        // ZCode emits RFC 3339 timestamps with fractional seconds (`2026-06-14T17:23:26.382Z`).
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
                  url.lastPathComponent.hasPrefix("model-io-sess")
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
                try CostUsageJsonl.scan(
                    fileURL: url,
                    maxLineBytes: 1024 * 1024,
                    prefixBytes: 1024 * 1024,
                    checkCancellation: checkCancellation)
                { line in
                    guard !line.wasTruncated,
                          let message = try? decoder.decode(WireMessage.self, from: line.bytes),
                          let usage = message.response?.usage
                    else {
                        return
                    }
                    let eventDate = message.completedAt.flatMap(parseTimestamp)
                        ?? resourceValues?.contentModificationDate
                        ?? now
                    let eventDay = calendar.startOfDay(for: eventDate)
                    guard eventDay >= start, eventDay <= end else { return }
                    // models.dev keys the Z.ai catalog by the lowercase model id (`glm-5.2`), while
                    // ZCode records the display casing (`GLM-5.2`).
                    let model = message.model?.modelId?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalizedModel = model?.isEmpty == false
                        ? model!.lowercased()
                        : "unknown"
                    events.append(UnifiedUsageEvent(
                        day: CostUsageLocalDay.key(from: eventDay, calendar: calendar),
                        model: normalizedModel,
                        billingProviderID: UsageProvider.zai.rawValue,
                        inputTokens: usage.inputTokens,
                        outputTokens: usage.outputTokens,
                        totalTokens: usage.totalTokens,
                        cacheReadTokens: usage.cacheReadTokens,
                        cacheCreationTokens: usage.cacheWriteTokens,
                        // Price at the official Z.ai API rate; the zero-priced coding-plan catalogs
                        // are intentionally excluded so we report the API-equivalent value.
                        pricingProviderIDs: ["zai", "zhipuai"]))
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
                historyLabel: "ZCode",
                defaultBillingProviderID: UsageProvider.zai.rawValue,
                modelsDevCacheRoot: modelsDevCacheRoot))
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
            .appendingPathComponent(".zcode", isDirectory: true)
    }
}
