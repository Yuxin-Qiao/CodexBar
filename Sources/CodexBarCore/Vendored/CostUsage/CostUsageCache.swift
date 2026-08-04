import Foundation

enum CostUsageCacheIO {
    /// Persistence budgets for the Codex cost cache. The artifact holds one entry per
    /// scanned session file plus per-file detail (rows, turn IDs, token snapshots) and is
    /// decoded and encoded as a single JSON document on every scan, so an unbounded corpus
    /// can otherwise grow it to multiple gigabytes. These bounds mirror the scan-side byte
    /// budgets; in-window data is never dropped, so reports stay complete.
    static let maxCacheFileBytes: Int = 256 * 1024 * 1024
    static let maxCacheFileEntries: Int = 25000
    /// Artifacts above this size are refused at load time and rebuilt by the bounded
    /// scanner instead of being decoded in one shot.
    static let maxCacheLoadBytes: Int = 1024 * 1024 * 1024

    /// Producer keys from older parser hashes whose caches are still valid under the current
    /// delta semantics. Cleared for #2037: interleave containment changed how cumulative
    /// totals are counted, so every earlier cache must be rebuilt.
    private static let compatibleCodexProducerKeys: Set<String> = []

    /// Parsing and attribution changes rotate the Codex parser producer key.
    /// Increment this artifact version only when the stored schema or cache layout becomes incompatible.
    private static func artifactVersion(for provider: UsageProvider) -> Int {
        switch provider {
        case .codex:
            11
        case .claude, .vertexai:
            6
        default:
            1
        }
    }

    private static func defaultCacheRoot() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("CodexBar", isDirectory: true)
    }

    static func cacheFileURL(provider: UsageProvider, cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? self.defaultCacheRoot()
        let artifactVersion = self.artifactVersion(for: provider)
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("\(provider.rawValue)-v\(artifactVersion).json", isDirectory: false)
    }

    static func load(
        provider: UsageProvider,
        cacheRoot: URL? = nil,
        producerKey: String? = nil,
        calendar: Calendar? = nil,
        maxCacheBytes: Int = CostUsageCacheIO.maxCacheLoadBytes) -> CostUsageCache
    {
        let url = self.cacheFileURL(provider: provider, cacheRoot: cacheRoot)
        let expectedProducerKey = producerKey ?? self.currentProducerKey(provider: provider)
        let compatibleProducerKeys = producerKey == nil && provider == .codex
            ? self.compatibleCodexProducerKeys
            : []
        if let decoded = self.loadCache(
            at: url,
            expectedProducerKey: expectedProducerKey,
            compatibleProducerKeys: compatibleProducerKeys,
            maxBytes: maxCacheBytes)
        {
            if let calendar, decoded.timeZoneIdentifier != calendar.timeZone.identifier {
                return CostUsageCache()
            }
            return decoded
        }
        return CostUsageCache()
    }

    static func loadCodexForMigration(
        cacheRoot: URL? = nil,
        producerKey: String? = nil,
        calendar: Calendar? = nil,
        maxCacheBytes: Int = CostUsageCacheIO.maxCacheLoadBytes) -> CostUsageCodexCacheLoadResult
    {
        let url = self.cacheFileURL(provider: .codex, cacheRoot: cacheRoot)
        guard let decoded = self.decodeCache(at: url, maxBytes: maxCacheBytes) else {
            return CostUsageCodexCacheLoadResult(cache: CostUsageCache(), incompatibleCache: nil)
        }
        if let calendar, decoded.timeZoneIdentifier != calendar.timeZone.identifier {
            return CostUsageCodexCacheLoadResult(cache: CostUsageCache(), incompatibleCache: nil)
        }

        let expectedProducerKey = producerKey ?? self.currentProducerKey(provider: .codex)
        let compatibleProducerKeys = producerKey == nil ? self.compatibleCodexProducerKeys : []
        if decoded.producerKey == expectedProducerKey
            || decoded.producerKey.map(compatibleProducerKeys.contains) == true
        {
            return CostUsageCodexCacheLoadResult(cache: decoded, incompatibleCache: nil)
        }

        // Never reuse parser-dependent offsets or totals from an incompatible producer. The
        // caller may still convert its last visible report into a compact, explicitly stale
        // presentation while the current producer rebuilds from byte zero.
        guard decoded.producerKey != nil else {
            return CostUsageCodexCacheLoadResult(cache: CostUsageCache(), incompatibleCache: nil)
        }
        return CostUsageCodexCacheLoadResult(cache: CostUsageCache(), incompatibleCache: decoded)
    }

    private static func loadCache(
        at url: URL,
        expectedProducerKey: String?,
        compatibleProducerKeys: Set<String>,
        maxBytes: Int) -> CostUsageCache?
    {
        guard let decoded = self.decodeCache(at: url, maxBytes: maxBytes) else { return nil }
        if let expectedProducerKey {
            guard decoded.producerKey == expectedProducerKey
                || decoded.producerKey.map(compatibleProducerKeys.contains) == true
            else { return nil }
        }
        return decoded
    }

    private static func decodeCache(at url: URL, maxBytes: Int) -> CostUsageCache? {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        guard fileSize <= maxBytes else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let decoded = try? JSONDecoder().decode(CostUsageCache.self, from: data)
        else { return nil }
        guard decoded.version == 1 else { return nil }
        return decoded
    }

    static func save(
        provider: UsageProvider,
        cache: CostUsageCache,
        cacheRoot: URL? = nil,
        producerKey: String? = nil,
        calendar: Calendar = .current,
        requestedScanWindow: (sinceKey: String, untilKey: String)? = nil,
        maxCacheBytes: Int = CostUsageCacheIO.maxCacheFileBytes,
        maxCacheEntries: Int = CostUsageCacheIO.maxCacheFileEntries)
    {
        let url = self.cacheFileURL(provider: provider, cacheRoot: cacheRoot)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var cache = cache
        cache.producerKey = producerKey ?? self.currentProducerKey(provider: provider)
        cache.timeZoneIdentifier = calendar.timeZone.identifier

        if provider == .codex {
            Self.pruneCodexCacheForBudget(
                &cache,
                requestedScanWindow: requestedScanWindow,
                maxCacheBytes: maxCacheBytes,
                maxCacheEntries: maxCacheEntries,
                previousArtifactBytes: Self.fileSize(at: url))
        }

        let data = (try? JSONEncoder().encode(cache)) ?? Data()
        try? data.write(to: url, options: [.atomic])
    }

    /// Bounds the Codex cache artifact when the corpus has outgrown the persistence budget.
    /// The all-time accumulation lives in per-file entries whose usage days fall outside the
    /// current scan window; the current report never reads those entries, and dropping them
    /// (with the same day-aggregate subtraction the scanner uses) keeps the artifact from
    /// growing without limit. Entries that are still resuming or that in-window forks depend
    /// on are preserved so bounded scans and fork baselines keep making progress. Priority
    /// turn IDs outside the window are only consulted for in-window rows, so they are trimmed
    /// to the window as well.
    private static func pruneCodexCacheForBudget(
        _ cache: inout CostUsageCache,
        requestedScanWindow: (sinceKey: String, untilKey: String)?,
        maxCacheBytes: Int,
        maxCacheEntries: Int,
        previousArtifactBytes: Int64?)
    {
        // Prune against the active requested scan window (what the current report reads),
        // not the historically widened retained union persisted in the cache.
        let sinceKey = requestedScanWindow?.sinceKey ?? cache.scanSinceKey
        let untilKey = requestedScanWindow?.untilKey ?? cache.scanUntilKey
        guard let sinceKey, let untilKey else { return }
        let overBudget = cache.files.count > maxCacheEntries
            || (previousArtifactBytes ?? 0) > Int64(maxCacheBytes)
        guard overBudget else { return }

        let neededParentSessionIDs = Set(cache.files.values.compactMap(\.forkedFromId))
        let outOfWindowKeys = cache.files.keys.filter { key in
            guard let usage = cache.files[key] else { return false }
            if usage.touchesCodexScanWindow(sinceKey: sinceKey, untilKey: untilKey) { return false }
            if usage.codexScanComplete == false { return false }
            if usage.codexJSONLResumeState != nil { return false }
            if usage.hasBufferedCodexForkRetryLines { return false }
            if let sessionId = usage.sessionId, neededParentSessionIDs.contains(sessionId) {
                return false
            }
            return true
        }
        for key in outOfWindowKeys {
            guard let old = cache.files.removeValue(forKey: key) else { continue }
            CostUsageScanner.applyFileDays(cache: &cache, fileDays: old.days, sign: -1)
        }
        if !outOfWindowKeys.isEmpty, requestedScanWindow != nil {
            // Entries outside the requested window are gone; narrow persisted coverage so a
            // later refresh does not treat them as in-window again.
            cache.scanSinceKey = requestedScanWindow?.sinceKey ?? cache.scanSinceKey
            cache.scanUntilKey = requestedScanWindow?.untilKey ?? cache.scanUntilKey
        }

        let inWindow: (String) -> Bool = { key in
            CostUsageScanner.CostUsageDayRange.isInRange(
                dayKey: key,
                since: sinceKey,
                until: untilKey)
        }
        if let idsByDay = cache.codexPriorityTurnIDsByDay {
            let trimmed = idsByDay.filter { inWindow($0.key) }
            cache.codexPriorityTurnIDsByDay = trimmed.isEmpty ? nil : trimmed
        }
        if let turnKeys = cache.codexPriorityTurnKeys {
            let trimmed = turnKeys.filter { inWindow($0.key) }
            cache.codexPriorityTurnKeys = trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func fileSize(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    static func currentProducerKey(
        provider: UsageProvider,
        parserHash: String = CodexParserHash.value) -> String?
    {
        guard provider == .codex else { return nil }
        return "\(provider.rawValue):cu:p\(parserHash)"
    }
}

struct CostUsageCodexCacheLoadResult {
    var cache: CostUsageCache
    var incompatibleCache: CostUsageCache?
}

struct CostUsageCache: Codable {
    var version: Int = 1
    var producerKey: String?
    var lastScanUnixMs: Int64 = 0
    var scanSinceKey: String?
    var scanUntilKey: String?
    var timeZoneIdentifier: String?
    var codexPricingKey: String?
    var codexPriorityMetadataKey: String?
    var codexProjectMetadataVersion: Int?
    var codexPriorityTurnKeys: [String: String]?
    var codexPriorityTurnIDsByDay: [String: [String]]?
    /// True when the last bounded scan left readable Codex work for a background catch-up pass.
    var codexScanCatchUpPending: Bool?
    var codexScanProcessedBytes: Int64?
    var codexScanTotalBytes: Int64?
    var codexScanCompletedFiles: Int?
    var codexScanTotalFiles: Int?
    /// Last user-visible report retained only while an incompatible or forced rebuild catches up.
    var codexPreviousReport: CostUsageCodexPreviousReport?
    /// Persistent session-id discovery and generation-scoped negative lookups for fork parents.
    var codexSessionDiscovery: CostUsageCodexSessionDiscovery?
    /// Resumable bounded discovery for recently modified rollouts in older date partitions.
    var codexActiveLookbackState: CostUsageCodexActiveLookbackState?

    /// filePath -> file usage
    var files: [String: CostUsageFileUsage] = [:]

    /// dayKey -> model -> packed usage
    var days: [String: [String: [Int]]] = [:]

    /// rootPath -> mtime (for Claude roots)
    var roots: [String: Int64]?
}

struct CostUsageCodexActiveLookbackState: Codable {
    var scanSinceKey: String
    var rootPaths: [String]
    var nextDayKeyByRoot: [String: String] = [:]
    var completedRootPaths: [String] = []
    var pendingFilePaths: [String] = []
    var legacyRecursivePendingRootPaths: [String] = []
}

struct CostUsageCodexSessionDiscovery: Codable {
    struct DirectoryStamp: Codable, Equatable {
        var mtimeUnixMs: Int64
        var jsonlFileCount: Int
    }

    struct FileStamp: Codable, Equatable {
        var mtimeUnixMs: Int64
        var size: Int64
        var fileId: String?
    }

    struct HeadScan: Codable {
        var path: String
        var offset: Int64
        var resumeState: CostUsageJsonl.ResumeState?
    }

    var roots: [String]
    var generation: String?
    var directoryStamps: [String: DirectoryStamp]
    var directoryPaths: [String]
    var nextDirectoryIndex: Int
    var filePaths: [String]
    var nextFileIndex: Int
    var fileStamps: [String: FileStamp]
    var headScan: HeadScan?
    var filePathBySessionId: [String: String]
    var missingSessionIds: [String]
    var pendingSessionIds: [String]
    var validationDirectoryIndex: Int
    var isComplete: Bool
}

struct CostUsageCodexPreviousReport: Codable, Equatable {
    struct ModelBreakdown: Codable, Equatable {
        var modelName: String
        var costUSD: Double?
        var totalTokens: Int?
        var requestCount: Int?
        var standardCostUSD: Double?
        var priorityCostUSD: Double?
        var standardTokens: Int?
        var priorityTokens: Int?

        init(_ breakdown: CostUsageDailyReport.ModelBreakdown) {
            self.modelName = breakdown.modelName
            self.costUSD = breakdown.costUSD
            self.totalTokens = breakdown.totalTokens
            self.requestCount = breakdown.requestCount
            self.standardCostUSD = breakdown.standardCostUSD
            self.priorityCostUSD = breakdown.priorityCostUSD
            self.standardTokens = breakdown.standardTokens
            self.priorityTokens = breakdown.priorityTokens
        }

        var dailyReportValue: CostUsageDailyReport.ModelBreakdown {
            CostUsageDailyReport.ModelBreakdown(
                modelName: self.modelName,
                costUSD: self.costUSD,
                totalTokens: self.totalTokens,
                requestCount: self.requestCount,
                standardCostUSD: self.standardCostUSD,
                priorityCostUSD: self.priorityCostUSD,
                standardTokens: self.standardTokens,
                priorityTokens: self.priorityTokens)
        }
    }

    struct Entry: Codable, Equatable {
        var date: String
        var inputTokens: Int?
        var cacheReadTokens: Int?
        var cacheCreationTokens: Int?
        var outputTokens: Int?
        var totalTokens: Int?
        var requestCount: Int?
        var costUSD: Double?
        var modelsUsed: [String]?
        var modelBreakdowns: [ModelBreakdown]?

        init(_ entry: CostUsageDailyReport.Entry) {
            self.date = entry.date
            self.inputTokens = entry.inputTokens
            self.cacheReadTokens = entry.cacheReadTokens
            self.cacheCreationTokens = entry.cacheCreationTokens
            self.outputTokens = entry.outputTokens
            self.totalTokens = entry.totalTokens
            self.requestCount = entry.requestCount
            self.costUSD = entry.costUSD
            self.modelsUsed = entry.modelsUsed
            self.modelBreakdowns = entry.modelBreakdowns?.map(ModelBreakdown.init)
        }

        var dailyReportValue: CostUsageDailyReport.Entry {
            CostUsageDailyReport.Entry(
                date: self.date,
                inputTokens: self.inputTokens,
                outputTokens: self.outputTokens,
                cacheReadTokens: self.cacheReadTokens,
                cacheCreationTokens: self.cacheCreationTokens,
                totalTokens: self.totalTokens,
                requestCount: self.requestCount,
                costUSD: self.costUSD,
                modelsUsed: self.modelsUsed,
                modelBreakdowns: self.modelBreakdowns?.map(\.dailyReportValue))
        }
    }

    struct Summary: Codable, Equatable {
        var totalInputTokens: Int?
        var totalOutputTokens: Int?
        var cacheReadTokens: Int?
        var cacheCreationTokens: Int?
        var totalTokens: Int?
        var totalCostUSD: Double?

        init(_ summary: CostUsageDailyReport.Summary) {
            self.totalInputTokens = summary.totalInputTokens
            self.totalOutputTokens = summary.totalOutputTokens
            self.cacheReadTokens = summary.cacheReadTokens
            self.cacheCreationTokens = summary.cacheCreationTokens
            self.totalTokens = summary.totalTokens
            self.totalCostUSD = summary.totalCostUSD
        }

        var dailyReportValue: CostUsageDailyReport.Summary {
            CostUsageDailyReport.Summary(
                totalInputTokens: self.totalInputTokens,
                totalOutputTokens: self.totalOutputTokens,
                cacheReadTokens: self.cacheReadTokens,
                cacheCreationTokens: self.cacheCreationTokens,
                totalTokens: self.totalTokens,
                totalCostUSD: self.totalCostUSD)
        }
    }

    var data: [Entry]
    var summary: Summary?
    var updatedAtUnixMs: Int64
    var scanSinceKey: String?
    var scanUntilKey: String?
    var timeZoneIdentifier: String?
    var roots: [String: Int64]?

    init?(
        report: CostUsageDailyReport,
        cache: CostUsageCache)
    {
        guard !report.data.isEmpty else { return nil }
        self.data = report.data.map(Entry.init)
        self.summary = report.summary.map(Summary.init)
        self.updatedAtUnixMs = cache.lastScanUnixMs
        self.scanSinceKey = cache.scanSinceKey
        self.scanUntilKey = cache.scanUntilKey
        self.timeZoneIdentifier = cache.timeZoneIdentifier
        self.roots = cache.roots
    }

    var report: CostUsageDailyReport {
        CostUsageDailyReport(
            data: self.data.map(\.dailyReportValue),
            summary: self.summary?.dailyReportValue)
    }

    var updatedAt: Date? {
        guard self.updatedAtUnixMs > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(self.updatedAtUnixMs) / 1000)
    }

    func matches(
        scanSinceKey: String,
        scanUntilKey: String,
        timeZoneIdentifier: String,
        roots: [String: Int64]) -> Bool
    {
        guard self.timeZoneIdentifier == timeZoneIdentifier,
              self.roots == roots,
              let cachedSince = self.scanSinceKey,
              let cachedUntil = self.scanUntilKey
        else { return false }
        return scanSinceKey >= cachedSince && scanUntilKey <= cachedUntil
    }
}

struct CostUsageFileUsage: Codable {
    var mtimeUnixMs: Int64
    var size: Int64
    var days: [String: [String: [Int]]]
    var parsedBytes: Int64?
    var lastModel: String?
    var lastTotals: CostUsageCodexTotals?
    var lastCountedTotals: CostUsageCodexTotals?
    var lastRawTotalsBaseline: CostUsageCodexTotals?
    var lastRawTotalsWatermark: CostUsageCodexTotals?
    var seenRawTotals: [CostUsageCodexTotals]?
    var hasDivergentTotals: Bool?
    var hasInterleavedTotals: Bool?
    var lastCodexTurnID: String?
    var sessionId: String?
    var forkedFromId: String?
    var forkBaselineDependencyKey: String?
    var projectPath: String?
    var canonicalProjectPath: String?
    var codexCostCacheComplete: Bool?
    var codexSession: CostUsageCodexSessionMetadata?
    var codexCostNanos: [String: [String: Int64]]?
    var codexPrioritySurchargeNanos: [String: [String: Int64]]?
    var codexStandardCostNanos: [String: [String: Int64]]?
    var codexPriorityCostNanos: [String: [String: Int64]]?
    var codexStandardTokens: [String: [String: Int]]?
    var codexPriorityTokens: [String: [String: Int]]?
    var codexTurnIDs: [String]?
    /// Refreshed by Codex normalization paths, never by sidecar cache validation.
    var codexWorkspaceContentFingerprint: String?
    var codexRows: [CostUsageScanner.CodexUsageRow]?
    /// Compact token events used to resolve fork baselines without rereading an entire parent rollout.
    var codexTokenSnapshots: [CostUsageCodexTokenSnapshot]?
    /// Sparse accumulator states for bounded lookup inside `codexTokenSnapshots`.
    var codexTokenCheckpoints: [CostUsageCodexTokenCheckpoint]?
    /// Allows binary-search and early-stop lookup only when event timestamps follow file order.
    var codexTokenTimestampsMonotonic: Bool?
    /// Validates that the indexed JSONL prefix was not rewritten before an append.
    var codexTokenIndexAnchor: CostUsageCodexTokenIndexAnchor?
    var claudeRows: [CostUsageScanner.ClaudeUsageRow]?
    /// Identity and latest observed size for an in-progress bounded Codex parse.
    var codexScanFileId: String?
    var codexScanTargetSize: Int64?
    var codexScanComplete: Bool?
    var codexJSONLResumeState: CostUsageJsonl.ResumeState?
    /// Compact relevant events retained while a subagent rollout awaits full-shape classification.
    var codexBufferedSubagentLines: [CostUsageScanner.CodexBufferedFastLine]?
    /// Parsed events retained when an ordinary fork is waiting for its parent baseline.
    var codexBufferedUnresolvedForkLines: [CostUsageScanner.CodexBufferedFastLine]?

    var hasBufferedCodexForkRetryLines: Bool {
        self.codexBufferedSubagentLines?.isEmpty == false
            || self.codexBufferedUnresolvedForkLines?.isEmpty == false
    }
}

struct CostUsageCodexSessionMetadata: Codable, Equatable {
    var sessionId: String?
    var forkedFromId: String?
    var cwd: String?
    var title: String?
    var startedAtUnixMs: Int64?
    var latestActivityUnixMs: Int64?

    var isEmpty: Bool {
        self.sessionId == nil
            && self.forkedFromId == nil
            && self.cwd == nil
            && self.title == nil
            && self.startedAtUnixMs == nil
            && self.latestActivityUnixMs == nil
    }

    func merging(_ newer: CostUsageCodexSessionMetadata) -> CostUsageCodexSessionMetadata {
        CostUsageCodexSessionMetadata(
            sessionId: newer.sessionId ?? self.sessionId,
            forkedFromId: newer.forkedFromId ?? self.forkedFromId,
            cwd: newer.cwd ?? self.cwd,
            title: newer.title ?? self.title,
            startedAtUnixMs: Self.earlier(self.startedAtUnixMs, newer.startedAtUnixMs),
            latestActivityUnixMs: Self.later(self.latestActivityUnixMs, newer.latestActivityUnixMs))
    }

    private static func earlier(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): min(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }

    private static func later(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): max(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }
}

struct CostUsageCodexTotals: Codable, Equatable {
    var input: Int
    var cached: Int
    var output: Int
    var reasoning: Int?

    init(input: Int, cached: Int, output: Int, reasoning: Int? = nil) {
        self.input = input
        self.cached = cached
        self.output = output
        self.reasoning = reasoning
    }
}

struct CostUsageCodexTokenSnapshot: Codable, Equatable {
    var timestamp: String
    var last: CostUsageCodexTotals?
    var total: CostUsageCodexTotals?
    var endOffset: Int64?

    init(
        timestamp: String,
        last: CostUsageCodexTotals?,
        total: CostUsageCodexTotals?,
        endOffset: Int64? = nil)
    {
        self.timestamp = timestamp
        self.last = last
        self.total = total
        self.endOffset = endOffset
    }
}

struct CostUsageCodexTokenAccumulatorState: Codable, Equatable {
    var countedTotals: CostUsageCodexTotals?
    var rawTotalsBaseline: CostUsageCodexTotals?
    var sawDivergentTotals: Bool
    var rawTotalsWatermark: CostUsageCodexTotals?
    var seenRawTotals: [CostUsageCodexTotals]
    var sawInterleavedTotals: Bool
}

struct CostUsageCodexTokenCheckpoint: Codable, Equatable {
    /// Index of the last token event already folded into `state`.
    var eventIndex: Int
    var timestamp: String
    var endOffset: Int64
    var state: CostUsageCodexTokenAccumulatorState
}

struct CostUsageCodexTokenIndexAnchor: Codable, Equatable {
    var indexedBytes: Int64
    var windowStart: Int64
    var sha256: String
}
