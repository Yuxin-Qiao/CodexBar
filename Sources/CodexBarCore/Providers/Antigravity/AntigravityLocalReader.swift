import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

// MARK: - Antigravity Local Reader (tokscale compatible)

enum AntigravityLocalReader {
    private static let maxBlobsPerDatabase = 10000
    private static let maxBytesPerBlob = 16 * 1024 * 1024
    private static let maxTotalBytesPerDatabase = 64 * 1024 * 1024
    private static let maxDatabases = 500
    private static let maxGlobalBytes = 128 * 1024 * 1024

    static func tokiCachePaths(home: URL? = nil) -> [URL] {
        let base: URL = if let home {
            home.appendingPathComponent(".config/tokscale/antigravity-cache/sessions", isDirectory: true)
        } else if let dir = ProcessInfo.processInfo.environment["TOKSCALE_CONFIG_DIR"], !dir.isEmpty {
            URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(
                "antigravity-cache/sessions",
                isDirectory: true)
        } else {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/tokscale/antigravity-cache/sessions", isDirectory: true)
        }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return contents
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func cliDBPaths(home: URL? = nil, max: Int = maxDatabases) -> [URL] {
        let env = ProcessInfo.processInfo.environment
        let baseHome = home ?? FileManager.default.homeDirectoryForCurrentUser
        var roots: [URL] = []
        let primary = AntigravityOfflineStore.conversationsDirectory(home: baseHome, env: env)
        let appData = AntigravityOfflineStore.appDataDirectory(home: baseHome, env: env)
        let appDataConv = appData.appendingPathComponent("conversations", isDirectory: true)

        for dir in [primary, appData, appDataConv] where FileManager.default.fileExists(atPath: dir.path) {
            if !roots.contains(dir) {
                roots.append(dir)
            }
        }

        var dbPaths: [URL] = []
        for root in roots {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            let filtered = contents.filter {
                $0.pathExtension.lowercased() == "db"
                    && !$0.lastPathComponent.hasSuffix("-wal")
                    && !$0.lastPathComponent.hasSuffix("-shm")
            }
            dbPaths.append(contentsOf: filtered)
            if dbPaths.count >= max {
                break
            }
        }
        let sorted = dbPaths.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return Array(sorted.prefix(max))
    }

    static func normalizeModelID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "unknown" }
        return trimmed
    }

    // MARK: - Checked arithmetic helpers

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let (res, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : res
    }

    private static func checkedSum(_ values: [Int]) -> Int? {
        var total = 0
        for v in values {
            guard let next = self.checkedAdd(total, v) else { return nil }
            total = next
        }
        return total
    }

    // MARK: - JSONL Parsing

    struct JSONLParseOutcome {
        let entries: [CostUsageDailyReport.Entry]
        let isComplete: Bool
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func parseJSONLCacheWithStatus(
        paths: [URL]? = nil,
        calendar: Calendar = .current,
        checkCancellation: (() throws -> Void)? = nil) rethrows -> JSONLParseOutcome
    {
        var entries: [CostUsageDailyReport.Entry] = []
        var seenResponseIds = Set<String>()
        var isComplete = true
        var globalBytes = 0

        for url in paths ?? self.tokiCachePaths() {
            try checkCancellation?()
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8)
            else {
                isComplete = false
                continue
            }
            if globalBytes + data.count > self.maxGlobalBytes {
                isComplete = false
                break
            }
            globalBytes += data.count

            var sessionModel: String?
            for line in text.components(separatedBy: .newlines) {
                try checkCancellation?()
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard let d = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                else {
                    isComplete = false
                    continue
                }
                let type = json["type"] as? String
                if type == "session_meta" {
                    sessionModel = json["modelId"] as? String ?? json["model_id"] as? String
                    continue
                }
                if type == "usage" || json["input"] != nil {
                    let rawModel =
                        (json["modelId"] as? String ?? json["model_id"] as? String ?? sessionModel ?? "unknown")
                    let modelId = self.normalizeModelID(rawModel)
                    guard let inputVal = json["input"] as? Int, inputVal >= 0,
                          let outputVal = json["output"] as? Int, outputVal >= 0
                    else {
                        isComplete = false
                        continue
                    }
                    let readVal = (json["cacheRead"] as? Int) ?? (json["cache_read"] as? Int) ?? 0
                    guard readVal >= 0 else { isComplete = false; continue }
                    let writeVal = (json["cacheWrite"] as? Int) ?? (json["cache_write"] as? Int) ?? 0
                    guard writeVal >= 0 else { isComplete = false; continue }
                    let reasonVal = (json["reasoning"] as? Int) ?? 0
                    guard reasonVal >= 0 else { isComplete = false; continue }

                    guard let t1 = self.checkedAdd(inputVal, outputVal),
                          let t2 = self.checkedAdd(t1, readVal),
                          let t3 = self.checkedAdd(t2, writeVal),
                          let total = self.checkedAdd(t3, reasonVal), total != 0
                    else {
                        isComplete = false
                        continue
                    }
                    let totalTokens = total

                    let ts: Int64
                    if let v = json["timestamp"] as? Int64 {
                        ts = v
                    } else if let v = json["timestamp"] as? Int {
                        guard let i64 = Int64(exactly: v) else { isComplete = false; continue }
                        ts = i64
                    } else if let v = json["timestamp"] as? Double {
                        guard v.isFinite, !v.isNaN, v >= 0, v <= Double(Int64.max),
                              let i64 = Int64(exactly: v) ?? Int64(exactly: floor(v))
                        else {
                            isComplete = false
                            continue
                        }
                        ts = i64
                    } else if let v = json["timestamp"] as? NSNumber {
                        let d = v.doubleValue
                        guard d.isFinite, !d.isNaN, d >= 0, d <= Double(Int64.max)
                        else {
                            isComplete = false
                            continue
                        }
                        ts = v.int64Value
                    } else {
                        isComplete = false
                        continue
                    }
                    guard ts > 0, ts <= 253_402_300_799_000 else {
                        isComplete = false
                        continue
                    }

                    let responseID = (json["responseId"] as? String ?? json["response_id"] as? String)
                    if let rid = responseID, !rid.isEmpty {
                        if seenResponseIds.contains(rid) { continue }
                    }

                    let date = self.timestampToDayKey(ts, calendar: calendar)

                    if let idx = entries.firstIndex(where: { $0.date == date }) {
                        let e = entries[idx]
                        guard let newInput = self.checkedAdd(e.inputTokens ?? 0, inputVal),
                              let newOutput = self.checkedAdd(e.outputTokens ?? 0, outputVal),
                              let newRead = self.checkedAdd(e.cacheReadTokens ?? 0, readVal),
                              let newWrite = self.checkedAdd(e.cacheCreationTokens ?? 0, writeVal),
                              let newReason = self.checkedAdd(e.reasoningTokens ?? 0, reasonVal),
                              let newTotal = self.checkedAdd(e.totalTokens ?? 0, totalTokens)
                        else {
                            isComplete = false
                            continue
                        }
                        guard let newBreakdown = self.checkedMergeBreakdown(
                            e.modelBreakdowns,
                            model: modelId,
                            tokens: totalTokens,
                            requestCount: 1,
                            inputTokens: inputVal,
                            outputTokens: outputVal,
                            cacheReadTokens: readVal,
                            cacheCreationTokens: writeVal,
                            reasoningTokens: reasonVal)
                        else {
                            isComplete = false
                            continue
                        }
                        if let rid = responseID, !rid.isEmpty { seenResponseIds.insert(rid) }
                        let ne = CostUsageDailyReport.Entry(
                            date: e.date,
                            inputTokens: newInput,
                            outputTokens: newOutput,
                            cacheReadTokens: newRead,
                            cacheCreationTokens: newWrite,
                            reasoningTokens: newReason,
                            totalTokens: newTotal,
                            requestCount: (e.requestCount ?? 0) + 1,
                            costUSD: nil,
                            modelsUsed: nil,
                            modelBreakdowns: newBreakdown)
                        entries[idx] = ne
                    } else {
                        if let rid = responseID, !rid.isEmpty { seenResponseIds.insert(rid) }
                        let e = CostUsageDailyReport.Entry(
                            date: date,
                            inputTokens: inputVal,
                            outputTokens: outputVal,
                            cacheReadTokens: readVal,
                            cacheCreationTokens: writeVal,
                            reasoningTokens: reasonVal,
                            totalTokens: totalTokens,
                            requestCount: 1,
                            costUSD: nil,
                            modelsUsed: nil,
                            modelBreakdowns: [
                                CostUsageDailyReport.ModelBreakdown(
                                    modelName: modelId,
                                    costUSD: nil,
                                    totalTokens: totalTokens,
                                    requestCount: 1,
                                    inputTokens: inputVal,
                                    outputTokens: outputVal,
                                    cacheReadTokens: readVal,
                                    cacheCreationTokens: writeVal,
                                    reasoningTokens: reasonVal),
                            ])
                        entries.append(e)
                    }
                }
            }
        }
        return JSONLParseOutcome(entries: entries.sorted { $0.date < $1.date }, isComplete: isComplete)
    }

    static func parseJSONLCache(paths: [URL]? = nil, calendar: Calendar = .current) -> [CostUsageDailyReport.Entry] {
        self.parseJSONLCacheWithStatus(paths: paths, calendar: calendar).entries
    }

    // MARK: - SQLite parsing with explicit completeness

    struct CLIParseOutcome {
        let entries: [CostUsageDailyReport.Entry]
        let isComplete: Bool
    }

    struct DailyReportResult {
        let report: CostUsageDailyReport
        let isComplete: Bool
        let isAvailable: Bool
    }

    static func parseCLIDBsWithStatus(
        paths: [URL]? = nil,
        calendar: Calendar = .current,
        checkCancellation: (() throws -> Void)? = nil) rethrows -> CLIParseOutcome
    {
        #if canImport(SQLite3) || canImport(CSQLite3)
        var entries: [CostUsageDailyReport.Entry] = []
        var seenResponseIds = Set<String>()
        var overallComplete = true
        var globalBytes = 0

        let urls = paths ?? self.cliDBPaths()
        if urls.count >= self.maxDatabases {
            overallComplete = false
        }
        for url in urls.prefix(self.maxDatabases) {
            try checkCancellation?()
            let outcome = self.parseSingleDB(
                at: url,
                calendar: calendar,
                seenResponseIds: &seenResponseIds,
                globalBytes: &globalBytes)
            for newEntry in outcome.entries {
                if let idx = entries.firstIndex(where: { $0.date == newEntry.date }) {
                    let existing = entries[idx]
                    guard let merged = self.checkedMergeEntry(existing, newEntry) else {
                        overallComplete = false
                        continue
                    }
                    entries[idx] = merged
                } else {
                    entries.append(newEntry)
                }
            }
            if !outcome.isComplete { overallComplete = false }
            if globalBytes > self.maxGlobalBytes {
                overallComplete = false
                break
            }
        }
        return CLIParseOutcome(entries: entries.sorted { $0.date < $1.date }, isComplete: overallComplete)
        #else
        return CLIParseOutcome(entries: [], isComplete: true)
        #endif
    }

    static func parseCLIDBs(paths: [URL]? = nil, calendar: Calendar = .current) -> [CostUsageDailyReport.Entry] {
        self.parseCLIDBsWithStatus(paths: paths, calendar: calendar).entries
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private static func parseSingleDB(
        at url: URL,
        calendar: Calendar,
        seenResponseIds: inout Set<String>,
        globalBytes: inout Int) -> CLIParseOutcome
    {
        #if canImport(SQLite3) || canImport(CSQLite3)
        var entries: [CostUsageDailyReport.Entry] = []
        var isComplete = true
        var totalDbBytes = 0
        var db: OpaquePointer?
        let openStatus = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil)
        guard openStatus == SQLITE_OK, let db else {
            if let db {
                sqlite3_close(db)
            }
            return CLIParseOutcome(entries: [], isComplete: false)
        }
        defer { sqlite3_close(db) }

        _ = sqlite3_exec(db, "BEGIN DEFERRED;", nil, nil, nil)
        defer { _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) }

        var genStmt: OpaquePointer?
        let mapLimit = Int32(self.maxBlobsPerDatabase + 1)
        guard sqlite3_prepare_v2(db, "SELECT data FROM gen_metadata ORDER BY idx LIMIT ?", -1, &genStmt, nil) ==
            SQLITE_OK, let genStmt
        else {
            return CLIParseOutcome(entries: [], isComplete: false)
        }

        sqlite3_bind_int(genStmt, 1, mapLimit)

        var rowCount = 0
        var rawBlobs: [[UInt8]] = []
        while true {
            let step = sqlite3_step(genStmt)
            if step == SQLITE_ROW {
                rowCount += 1
                let count = Int(sqlite3_column_bytes(genStmt, 0))
                totalDbBytes += count
                globalBytes += count

                if rowCount > self.maxBlobsPerDatabase {
                    isComplete = false
                    break
                }
                guard let ptr = sqlite3_column_blob(genStmt, 0) else {
                    isComplete = false
                    continue
                }
                if count <= 0 || count > self.maxBytesPerBlob {
                    isComplete = false
                    continue
                }
                if totalDbBytes > self.maxTotalBytesPerDatabase || globalBytes > self.maxGlobalBytes {
                    isComplete = false
                    break
                }
                let blob = Array(UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: UInt8.self), count: count))
                rawBlobs.append(blob)
            } else if step == SQLITE_DONE {
                break
            } else {
                isComplete = false
                break
            }
        }
        sqlite3_finalize(genStmt)

        // Pass 1: Build labelToModel map
        var labelToModel: [String: String] = [:]
        for blob in rawBlobs {
            guard let turn = AntigravityProtoReader.parseTurn(blob) else { continue }
            if let model = turn.model, let label = turn.label {
                let canon = self.normalizeModelID(model)
                if let existing = labelToModel[label], existing != canon {
                    labelToModel[label] = ""
                } else {
                    labelToModel[label] = canon
                }
            }
        }

        // Pass 2: Parse and aggregate turns
        for blob in rawBlobs {
            guard let turn = AntigravityProtoReader.parseTurn(blob),
                  let usage = turn.usage,
                  let timestampMs = turn.timestampMs
            else {
                isComplete = false
                continue
            }

            guard let inputTokens = self.checkedAdd(usage.systemPrompt, usage.newInput),
                  let t1 = self.checkedAdd(inputTokens, usage.output),
                  let t2 = self.checkedAdd(t1, usage.cacheRead),
                  let total = self.checkedAdd(t2, usage.reasoning), total != 0
            else {
                isComplete = false
                continue
            }
            let totalTokens = total

            if let responseID = usage.responseID, !responseID.isEmpty {
                if seenResponseIds.contains(responseID) { continue }
            }

            let date = self.timestampToDayKey(timestampMs, calendar: calendar)
            let rawModel = turn.model ?? turn.label
                .flatMap { labelToModel[$0]?.isEmpty == false ? labelToModel[$0] : nil } ?? "unknown"
            let modelId = self.normalizeModelID(rawModel)

            if let idx = entries.firstIndex(where: { $0.date == date }) {
                let e = entries[idx]
                guard let newInput = self.checkedAdd(e.inputTokens ?? 0, inputTokens),
                      let newOutput = self.checkedAdd(e.outputTokens ?? 0, usage.output),
                      let newCacheRead = self.checkedAdd(e.cacheReadTokens ?? 0, usage.cacheRead),
                      let newReason = self.checkedAdd(e.reasoningTokens ?? 0, usage.reasoning),
                      let newTotal = self.checkedAdd(e.totalTokens ?? 0, totalTokens)
                else {
                    isComplete = false
                    continue
                }
                guard let newBreakdown = self.checkedMergeBreakdown(
                    e.modelBreakdowns,
                    model: modelId,
                    tokens: totalTokens,
                    requestCount: 1,
                    inputTokens: inputTokens,
                    outputTokens: usage.output,
                    cacheReadTokens: usage.cacheRead,
                    cacheCreationTokens: 0,
                    reasoningTokens: usage.reasoning)
                else {
                    isComplete = false
                    continue
                }
                if let responseID = usage.responseID, !responseID.isEmpty {
                    seenResponseIds.insert(responseID)
                }
                let ne = CostUsageDailyReport.Entry(
                    date: e.date,
                    inputTokens: newInput,
                    outputTokens: newOutput,
                    cacheReadTokens: newCacheRead,
                    cacheCreationTokens: e.cacheCreationTokens ?? 0,
                    reasoningTokens: newReason,
                    totalTokens: newTotal,
                    requestCount: (e.requestCount ?? 0) + 1,
                    costUSD: nil,
                    modelsUsed: nil,
                    modelBreakdowns: newBreakdown)
                entries[idx] = ne
            } else {
                if let responseID = usage.responseID, !responseID.isEmpty {
                    seenResponseIds.insert(responseID)
                }
                let e = CostUsageDailyReport.Entry(
                    date: date,
                    inputTokens: inputTokens,
                    outputTokens: usage.output,
                    cacheReadTokens: usage.cacheRead,
                    cacheCreationTokens: 0,
                    reasoningTokens: usage.reasoning,
                    totalTokens: totalTokens,
                    requestCount: 1,
                    costUSD: nil,
                    modelsUsed: nil,
                    modelBreakdowns: [CostUsageDailyReport.ModelBreakdown(
                        modelName: modelId,
                        costUSD: nil,
                        totalTokens: totalTokens,
                        requestCount: 1,
                        inputTokens: inputTokens,
                        outputTokens: usage.output,
                        cacheReadTokens: usage.cacheRead,
                        cacheCreationTokens: 0,
                        reasoningTokens: usage.reasoning)])
                entries.append(e)
            }
        }

        return CLIParseOutcome(entries: entries.sorted { $0.date < $1.date }, isComplete: isComplete)
        #else
        return CLIParseOutcome(entries: [], isComplete: true)
        #endif
    }

    private static func checkedMergeEntry(
        _ existing: CostUsageDailyReport.Entry,
        _ new: CostUsageDailyReport.Entry) -> CostUsageDailyReport.Entry?
    {
        guard let input = self.checkedAdd(existing.inputTokens ?? 0, new.inputTokens ?? 0),
              let output = self.checkedAdd(existing.outputTokens ?? 0, new.outputTokens ?? 0),
              let read = self.checkedAdd(existing.cacheReadTokens ?? 0, new.cacheReadTokens ?? 0),
              let creation = self.checkedAdd(existing.cacheCreationTokens ?? 0, new.cacheCreationTokens ?? 0),
              let reason = self.checkedAdd(existing.reasoningTokens ?? 0, new.reasoningTokens ?? 0),
              let total = self.checkedAdd(existing.totalTokens ?? 0, new.totalTokens ?? 0),
              let requests = self.checkedAdd(existing.requestCount ?? 0, new.requestCount ?? 0) else { return nil }
        let breakdowns: [CostUsageDailyReport.ModelBreakdown]?
        if let ex = existing.modelBreakdowns, let nw = new.modelBreakdowns {
            var merged = ex
            for b in nw {
                guard let updated = self.checkedMergeBreakdown(
                    merged,
                    model: b.modelName,
                    tokens: b.totalTokens ?? 0,
                    requestCount: b.requestCount ?? 1,
                    inputTokens: b.inputTokens,
                    outputTokens: b.outputTokens,
                    cacheReadTokens: b.cacheReadTokens,
                    cacheCreationTokens: b.cacheCreationTokens,
                    reasoningTokens: b.reasoningTokens) else { return nil }
                merged = updated
            }
            breakdowns = merged
        } else {
            breakdowns = existing.modelBreakdowns ?? new.modelBreakdowns
        }
        return CostUsageDailyReport.Entry(
            date: existing.date,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: read,
            cacheCreationTokens: creation,
            reasoningTokens: reason,
            totalTokens: total,
            requestCount: requests,
            costUSD: nil,
            modelsUsed: nil,
            modelBreakdowns: breakdowns)
    }

    static func makeDailyReportWithStatus(
        home: URL? = nil,
        calendar: Calendar = .current,
        checkCancellation: (() throws -> Void)? = nil) rethrows -> DailyReportResult
    {
        let dbPaths = self.cliDBPaths(home: home)
        if !dbPaths.isEmpty {
            let dbOutcome = try self.parseCLIDBsWithStatus(
                paths: dbPaths,
                calendar: calendar,
                checkCancellation: checkCancellation)
            if dbOutcome.isComplete {
                let summaryTotal = self.checkedSum(dbOutcome.entries.compactMap(\.totalTokens))
                let report = CostUsageDailyReport(
                    data: dbOutcome.entries,
                    summary: dbOutcome.entries.isEmpty ? nil : .init(
                        totalInputTokens: nil,
                        totalOutputTokens: nil,
                        totalTokens: summaryTotal,
                        totalCostUSD: nil))
                return DailyReportResult(report: report, isComplete: true, isAvailable: true)
            } else {
                return DailyReportResult(
                    report: CostUsageDailyReport(data: [], summary: nil),
                    isComplete: false,
                    isAvailable: false)
            }
        }

        let jsonlPaths = self.tokiCachePaths(home: home)
        if !jsonlPaths.isEmpty {
            let jsonlOutcome = try self.parseJSONLCacheWithStatus(
                paths: jsonlPaths,
                calendar: calendar,
                checkCancellation: checkCancellation)
            if jsonlOutcome.isComplete {
                let summaryTotal = self.checkedSum(jsonlOutcome.entries.compactMap(\.totalTokens))
                let report = CostUsageDailyReport(
                    data: jsonlOutcome.entries,
                    summary: jsonlOutcome.entries.isEmpty ? nil : .init(
                        totalInputTokens: nil,
                        totalOutputTokens: nil,
                        totalTokens: summaryTotal,
                        totalCostUSD: nil))
                return DailyReportResult(report: report, isComplete: true, isAvailable: true)
            } else {
                return DailyReportResult(
                    report: CostUsageDailyReport(data: [], summary: nil),
                    isComplete: false,
                    isAvailable: false)
            }
        }

        return DailyReportResult(
            report: CostUsageDailyReport(data: [], summary: nil),
            isComplete: true,
            isAvailable: false)
    }

    static func makeDailyReport(home: URL? = nil, calendar: Calendar = .current) -> CostUsageDailyReport {
        self.makeDailyReportWithStatus(home: home, calendar: calendar).report
    }

    private static func timestampToDayKey(_ ms: Int64, calendar: Calendar = .current) -> String {
        let sec = Double(ms) / 1000.0
        let date = Date(timeIntervalSince1970: sec)
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    private static func checkedMergeBreakdown(
        _ ex: [CostUsageDailyReport.ModelBreakdown]?,
        model: String,
        tokens: Int,
        requestCount: Int = 1,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil,
        reasoningTokens: Int? = nil) -> [CostUsageDailyReport.ModelBreakdown]?
    {
        var arr = ex ?? []
        if let i = arr.firstIndex(where: { $0.modelName == model }) {
            let b = arr[i]
            guard let newTotal = self.checkedAdd(b.totalTokens ?? 0, tokens),
                  let newRequests = self.checkedAdd(b.requestCount ?? 0, requestCount),
                  let newInput = self.checkedAdd(b.inputTokens ?? 0, inputTokens ?? 0),
                  let newOutput = self.checkedAdd(b.outputTokens ?? 0, outputTokens ?? 0),
                  let newRead = self.checkedAdd(b.cacheReadTokens ?? 0, cacheReadTokens ?? 0),
                  let newCreate = self.checkedAdd(b.cacheCreationTokens ?? 0, cacheCreationTokens ?? 0),
                  let newReason = self.checkedAdd(b.reasoningTokens ?? 0, reasoningTokens ?? 0) else { return nil }
            arr[i] = CostUsageDailyReport.ModelBreakdown(
                modelName: b.modelName,
                costUSD: nil,
                totalTokens: newTotal,
                requestCount: newRequests,
                inputTokens: newInput,
                outputTokens: newOutput,
                cacheReadTokens: newRead,
                cacheCreationTokens: newCreate,
                reasoningTokens: newReason)
        } else {
            arr.append(CostUsageDailyReport.ModelBreakdown(
                modelName: model,
                costUSD: nil,
                totalTokens: tokens,
                requestCount: requestCount,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheCreationTokens: cacheCreationTokens,
                reasoningTokens: reasoningTokens))
        }
        return arr
    }

    private static func mergeBreakdown(
        _ ex: [CostUsageDailyReport.ModelBreakdown]?,
        model: String,
        tokens: Int,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil,
        reasoningTokens: Int? = nil) -> [CostUsageDailyReport.ModelBreakdown]
    {
        self.checkedMergeBreakdown(
            ex,
            model: model,
            tokens: tokens,
            requestCount: 1,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            reasoningTokens: reasoningTokens) ?? (ex ?? [])
    }
}

/// Lightweight Protobuf wire-format reader (zero external dependencies).
struct AntigravityProtoReader {
    let bytes: [UInt8]
    var offset: Int = 0
    var isMalformed: Bool = false

    struct ParsedUsage {
        var systemPrompt: Int = 0
        var newInput: Int = 0
        var cacheRead: Int = 0
        var output: Int = 0
        var reasoning: Int = 0
        var responseID: String?
    }

    struct ParsedTurn {
        var usage: ParsedUsage?
        var timestampMs: Int64?
        var model: String?
        var label: String?
    }

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt32 = 0
        var byteCount = 0
        while self.offset < self.bytes.count {
            let byte = self.bytes[self.offset]
            self.offset += 1
            byteCount += 1
            if byteCount == 10 {
                if (byte & 0x80) != 0 || (byte & 0x7F) > 1 {
                    self.isMalformed = true
                    return nil
                }
            }
            let payload = UInt64(byte & 0x7F)
            if shift >= 64 || (shift == 63 && payload > 1) {
                self.isMalformed = true
                return nil
            }
            result |= payload << shift
            if (byte & 0x80) == 0 { return result }
            shift += 7
            if shift >= 64 || byteCount >= 10 {
                self.isMalformed = true
                return nil
            }
        }
        self.isMalformed = true
        return nil
    }

    mutating func nextField() -> (fieldNumber: Int, wireType: Int, data: [UInt8]?, varintValue: UInt64?)? {
        guard self.offset < self.bytes.count else { return nil }
        guard let tag = self.readVarint(), tag <= UInt64(Int.max) else {
            self.isMalformed = true
            return nil
        }
        let fieldNumber = Int(tag >> 3)
        let wireType = Int(tag & 0x07)
        switch wireType {
        case 0:
            guard let val = self.readVarint() else {
                self.isMalformed = true
                return nil
            }
            return (fieldNumber, wireType, nil, val)
        case 1:
            guard let end = self.offset.addingReportingOverflow(8).overflow ? nil : self.offset + 8,
                  end <= self.bytes.count
            else {
                self.isMalformed = true
                return nil
            }
            let slice = Array(self.bytes[self.offset..<end])
            self.offset = end
            return (fieldNumber, wireType, slice, nil)
        case 2:
            guard let length = self.readVarint(),
                  let len = Int(exactly: length), len >= 0,
                  let end = self.offset.addingReportingOverflow(len).overflow ? nil : self.offset + len,
                  end <= self.bytes.count
            else {
                self.isMalformed = true
                return nil
            }
            let slice = Array(self.bytes[self.offset..<end])
            self.offset = end
            return (fieldNumber, wireType, slice, nil)
        case 5:
            guard let end = self.offset.addingReportingOverflow(4).overflow ? nil : self.offset + 4,
                  end <= self.bytes.count
            else {
                self.isMalformed = true
                return nil
            }
            let slice = Array(self.bytes[self.offset..<end])
            self.offset = end
            return (fieldNumber, wireType, slice, nil)
        default:
            self.isMalformed = true
            return nil
        }
    }

    static func parseTurn(_ rootBytes: [UInt8]) -> ParsedTurn? {
        var reader = AntigravityProtoReader(bytes: rootBytes)
        var chatModelSlice: [UInt8]?
        while let field = reader.nextField() {
            if field.fieldNumber == 1, field.wireType == 2 {
                chatModelSlice = field.data
            }
        }
        guard !reader.isMalformed, let chatModelSlice else { return nil }

        var chatReader = AntigravityProtoReader(bytes: chatModelSlice)
        var turn = ParsedTurn()

        while let field = chatReader.nextField() {
            switch field.fieldNumber {
            case 4: // usage
                guard field.wireType == 2, let data = field.data,
                      let usage = self.parseUsage(data)
                else { return nil }
                turn.usage = usage
            case 9: // gen
                guard field.wireType == 2, let data = field.data,
                      let ts = self.parseGenTimestamp(data)
                else { return nil }
                turn.timestampMs = ts
            case 19: // model string
                guard field.wireType == 2, let data = field.data,
                      let str = String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !str.isEmpty
                else { return nil }
                turn.model = str
            case 21: // label string
                guard field.wireType == 2, let data = field.data,
                      let str = String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !str.isEmpty
                else { return nil }
                turn.label = str
            default:
                break
            }
        }
        guard !chatReader.isMalformed else { return nil }
        return turn
    }

    private static func parseUsage(_ usageBytes: [UInt8]) -> ParsedUsage? {
        var reader = AntigravityProtoReader(bytes: usageBytes)
        var usage = ParsedUsage()
        while let field = reader.nextField() {
            switch field.fieldNumber {
            case 1:
                guard field.wireType == 0, let val = field.varintValue, let iv = Int(exactly: val),
                      iv >= 0 else { return nil }
                usage.systemPrompt = iv
            case 2:
                guard field.wireType == 0, let val = field.varintValue, let iv = Int(exactly: val),
                      iv >= 0 else { return nil }
                usage.newInput = iv
            case 5:
                guard field.wireType == 0, let val = field.varintValue, let iv = Int(exactly: val),
                      iv >= 0 else { return nil }
                usage.cacheRead = iv
            case 9:
                guard field.wireType == 0, let val = field.varintValue, let iv = Int(exactly: val),
                      iv >= 0 else { return nil }
                usage.output = iv
            case 10:
                guard field.wireType == 0, let val = field.varintValue, let iv = Int(exactly: val),
                      iv >= 0 else { return nil }
                usage.reasoning = iv
            case 11:
                guard field.wireType == 2, let data = field.data,
                      let str = String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                else { return nil }
                usage.responseID = str.isEmpty ? nil : str
            default:
                break
            }
        }
        guard !reader.isMalformed else { return nil }
        return usage
    }

    private static func parseGenTimestamp(_ genBytes: [UInt8]) -> Int64? {
        var reader = AntigravityProtoReader(bytes: genBytes)
        var genTimeSlice: [UInt8]?
        while let field = reader.nextField() {
            if field.fieldNumber == 4, field.wireType == 2 {
                genTimeSlice = field.data
            }
        }
        guard !reader.isMalformed, let genTimeSlice else { return nil }

        var timeReader = AntigravityProtoReader(bytes: genTimeSlice)
        var secondsVal: UInt64?
        var nanosVal: UInt64 = 0
        while let field = timeReader.nextField() {
            switch field.fieldNumber {
            case 1:
                guard field.wireType == 0, let val = field.varintValue else { return nil }
                secondsVal = val
            case 2:
                guard field.wireType == 0, let val = field.varintValue, val <= 999_999_999 else { return nil }
                nanosVal = val
            default:
                break
            }
        }
        guard !timeReader.isMalformed, let sec = secondsVal else { return nil }
        guard let seconds = Int64(exactly: sec),
              let nanos = Int64(exactly: nanosVal),
              let ms = seconds.checkedMultiply(1000),
              let total = ms.checkedAdd(nanos / 1_000_000),
              total > 0, total <= 253_402_300_799_000
        else { return nil }
        return total
    }

    static func messageField(_ data: [UInt8], field: Int) -> [UInt8]? {
        var reader = AntigravityProtoReader(bytes: data)
        while let (f, wire, slice, _) = reader.nextField() {
            if f == field, wire == 2, let slice {
                return slice
            }
        }
        return nil
    }

    static func varintField(_ data: [UInt8], field: Int) -> UInt64? {
        var reader = AntigravityProtoReader(bytes: data)
        while let (f, wire, _, val) = reader.nextField() {
            if f == field, wire == 0, let val {
                return val
            }
        }
        return nil
    }

    static func stringField(_ data: [UInt8], field: Int) -> String? {
        guard let bytes = self.messageField(data, field: field) else { return nil }
        guard let text = String(bytes: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }

    static func protoTimestampMs(_ data: [UInt8]) -> Int64? {
        guard let secondsVal = self.varintField(data, field: 1) else { return nil }
        let nanosVal = self.varintField(data, field: 2) ?? 0
        guard nanosVal <= 999_999_999 else { return nil }
        guard let seconds = Int64(exactly: secondsVal),
              let nanos = Int64(exactly: nanosVal),
              let ms = seconds.checkedMultiply(1000),
              let total = ms.checkedAdd(nanos / 1_000_000)
        else { return nil }
        return total
    }
}

extension Int64 {
    fileprivate func checkedMultiply(_ other: Int64) -> Int64? {
        let (res, overflow) = self.multipliedReportingOverflow(by: other)
        return overflow ? nil : res
    }

    fileprivate func checkedAdd(_ other: Int64) -> Int64? {
        let (res, overflow) = self.addingReportingOverflow(other)
        return overflow ? nil : res
    }
}
