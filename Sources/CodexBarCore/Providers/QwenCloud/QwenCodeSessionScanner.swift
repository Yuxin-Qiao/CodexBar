import Foundation

/// Reads Qwen Code's local JSONL history as a thin parser over the shared aggregation engine.
///
/// Qwen stores assistant messages under `~/.qwen/projects/*/chats/*.jsonl`. The format is also
/// consumed by tokscale. The scanner is deliberately bounded and cancellable so enabling a long
/// history cannot turn dashboard refresh into an unbounded filesystem crawl.
///
/// This scanner only walks files and maps each assistant message to a `UnifiedUsageEvent`. The
/// cached-prefix split (Qwen's `promptTokenCount` already includes `cachedContentTokenCount`),
/// models.dev pricing, reasoning/output accounting, day bucketing, and snapshot construction are
/// all handled once by `UsageEventAggregator`.
public enum QwenCodeSessionScanner {
    public static let homeEnvironmentKey = "QWEN_HOME"
    public static let defaultHistoryDays = 30
    public static let maximumFiles = 20000
    public static let maximumBytes = 512 * 1024 * 1024

    private struct WireMessage: Decodable {
        struct Usage: Decodable {
            let promptTokenCount: Int?
            let candidatesTokenCount: Int?
            let thoughtsTokenCount: Int?
            let cachedContentTokenCount: Int?
        }

        let type: String?
        let model: String?
        let timestamp: String?
        let usageMetadata: Usage?
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
        let home = self.homeURL(environment: environment)
        let root = home.appendingPathComponent("projects", isDirectory: true)
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
        // Qwen emits both whole-second and fractional-second RFC 3339 timestamps. The default
        // formatter rejects fractional seconds and would silently collapse those messages onto the
        // file's modification day, so try a fractional-seconds formatter first.
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
                  url.deletingLastPathComponent().lastPathComponent == "chats"
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
                          message.type == "assistant",
                          let usage = message.usageMetadata
                    else {
                        return
                    }
                    let eventDate = message.timestamp.flatMap(parseTimestamp)
                        ?? resourceValues?.contentModificationDate
                        ?? now
                    let eventDay = calendar.startOfDay(for: eventDate)
                    guard eventDay >= start, eventDay <= end else { return }
                    let model = message.model?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalizedModel = model?.isEmpty == false ? model! : "unknown"
                    // Reasoning ("thoughts") is billed as output. Fold it into the event's output so
                    // the engine prices output correctly, and also pass it through as the reasoning
                    // sub-bucket for display. `promptTokenCount` carries no separate total, so the
                    // engine falls back to subtracting the cached prefix.
                    let candidates = max(0, usage.candidatesTokenCount ?? 0)
                    let thoughts = max(0, usage.thoughtsTokenCount ?? 0)
                    events.append(UnifiedUsageEvent(
                        day: CostUsageLocalDay.key(from: eventDay, calendar: calendar),
                        model: normalizedModel,
                        billingProviderID: UsageProvider.qwencloud.rawValue,
                        inputTokens: usage.promptTokenCount,
                        outputTokens: candidates + thoughts,
                        totalTokens: nil,
                        cacheReadTokens: usage.cachedContentTokenCount,
                        cacheCreationTokens: nil,
                        reasoningTokens: thoughts,
                        pricingProviderIDs: ["alibaba", "alibaba-cn"]))
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
                historyLabel: "Qwen Code CLI",
                defaultBillingProviderID: UsageProvider.qwencloud.rawValue,
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
            .appendingPathComponent(".qwen", isDirectory: true)
    }
}
