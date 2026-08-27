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
        return contents.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func cliDBPaths(home: URL? = nil) -> [URL] {
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
        }
        return dbPaths.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func normalizeModelID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "unknown" }
        return trimmed
    }

    // MARK: - Checked helpers

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

    static func parseJSONLCache(paths: [URL]? = nil, calendar: Calendar = .current) -> [CostUsageDailyReport.Entry] {
        var entries: [CostUsageDailyReport.Entry] = []
        var seenResponseIds = Set<String>()
        for url in paths ?? self.tokiCachePaths() {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            var sessionModel: String?
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let d = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                let type = json["type"] as? String
                if type == "session_meta" {
                    sessionModel = json["modelId"] as? String ?? json["model_id"] as? String
                    continue
                }
                if type == "usage" || json["input"] != nil {
                    if let rid = (json["responseId"] as? String ?? json["response_id"] as? String), !rid.isEmpty {
                        if seenResponseIds.contains(rid) { continue }
                        seenResponseIds.insert(rid)
                    }
                    let rawModel =
                        (json["modelId"] as? String ?? json["model_id"] as? String ?? sessionModel ?? "unknown")
                    let modelId = self.normalizeModelID(rawModel)
                    let input = max(0, (json["input"] as? Int) ?? 0)
                    let output = max(0, (json["output"] as? Int) ?? 0)
                    let read = max(0, (json["cacheRead"] as? Int) ?? (json["cache_read"] as? Int) ?? 0)
                    let write = max(0, (json["cacheWrite"] as? Int) ?? (json["cache_write"] as? Int) ?? 0)
                    let reason = max(0, (json["reasoning"] as? Int) ?? 0)
                    guard let t1 = self.checkedAdd(input, output),
                          let t2 = self.checkedAdd(t1, read),
                          let t3 = self.checkedAdd(t2, write),
                          let total = self.checkedAdd(t3, reason), total != 0 else { continue }
                    let totalTokens = total
                    let ts: Int64
                    if let v = json["timestamp"] as? Int64 {
                        ts = v
                    } else if let v = json["timestamp"] as? Int {
                        ts = Int64(v)
                    } else if let v = json["timestamp"] as? Double {
                        ts = Int64(v)
                    } else if let v = json["timestamp"] as? NSNumber {
                        ts = v.int64Value
                    } else {
                        continue
                    }
                    let date = self.timestampToDayKey(ts, calendar: calendar)

                    if let idx = entries.firstIndex(where: { $0.date == date }) {
                        let e = entries[idx]
                        guard let newInput = self.checkedAdd(e.inputTokens ?? 0, input),
                              let newOutput = self.checkedAdd(e.outputTokens ?? 0, output),
                              let newRead = self.checkedAdd(e.cacheReadTokens ?? 0, read),
                              let newWrite = self.checkedAdd(e.cacheCreationTokens ?? 0, write),
                              let newReason = self.checkedAdd(e.reasoningTokens ?? 0, reason),
                              let newTotal = self.checkedAdd(e.totalTokens ?? 0, totalTokens) else { continue }
                        guard let newBreakdown = self.checkedMergeBreakdown(
                            e.modelBreakdowns,
                            model: modelId,
                            tokens: totalTokens,
                            inputTokens: input,
                            outputTokens: output,
                            cacheReadTokens: read,
                            cacheCreationTokens: write,
                            reasoningTokens: reason) else { continue }
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
                        let e = CostUsageDailyReport.Entry(
                            date: date,
                            inputTokens: input,
                            outputTokens: output,
                            cacheReadTokens: read,
                            cacheCreationTokens: write,
                            reasoningTokens: reason,
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
                                    inputTokens: input,
                                    outputTokens: output,
                                    cacheReadTokens: read,
                                    cacheCreationTokens: write,
                                    reasoningTokens: reason),
                            ])
                        entries.append(e)
                    }
                }
            }
        }
        return entries.sorted { $0.date < $1.date }
    }

    struct CLIParseOutcome {
        let entries: [CostUsageDailyReport.Entry]
        let isComplete: Bool
    }

    static func parseCLIDBsWithStatus(
        paths: [URL]? = nil,
        calendar: Calendar = .current) -> CLIParseOutcome
    {
        #if canImport(SQLite3) || canImport(CSQLite3)
        var entries: [CostUsageDailyReport.Entry] = []
        var seenResponseIds = Set<String>()
        var overallComplete = true
        for url in paths ?? self.cliDBPaths() {
            let outcome = self.parseSingleDB(at: url, calendar: calendar, seenResponseIds: &seenResponseIds)
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
        seenResponseIds: inout Set<String>) -> CLIParseOutcome
    {
        #if canImport(SQLite3) || canImport(CSQLite3)
        var entries: [CostUsageDailyReport.Entry] = []
        var isComplete = true
        var totalBytes = 0
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return CLIParseOutcome(entries: [], isComplete: false)
        }
        defer { sqlite3_close(db) }
        var sessionCreatedMs: Int64?
        var metaStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT data FROM trajectory_metadata_blob LIMIT 1", -1, &metaStmt, nil) == SQLITE_OK,
           let metaStmt
        {
            let step = sqlite3_step(metaStmt)
            if step == SQLITE_ROW, let blobPtr = sqlite3_column_blob(metaStmt, 0) {
                let blobBytes = Int(sqlite3_column_bytes(metaStmt, 0))
                if blobBytes > 0, blobBytes <= self.maxBytesPerBlob {
                    let blobData = Array(UnsafeBufferPointer(
                        start: blobPtr.assumingMemoryBound(to: UInt8.self),
                        count: blobBytes))
                    if let tsData = AntigravityProtoReader.messageField(blobData, field: 2),
                       let tsMs = AntigravityProtoReader.protoTimestampMs(tsData)
                    {
                        sessionCreatedMs = tsMs
                    }
                } else if blobBytes > self.maxBytesPerBlob { isComplete = false }
            } else if step != SQLITE_DONE, step != SQLITE_ROW { isComplete = false }
            sqlite3_finalize(metaStmt)
        } else { isComplete = false }
        var labelToModel: [String: String] = [:]
        var genStmt: OpaquePointer?
        let mapLimit = Int32(self.maxBlobsPerDatabase + 1)
        guard sqlite3_prepare_v2(db, "SELECT data FROM gen_metadata ORDER BY idx LIMIT ?", -1, &genStmt, nil) ==
            SQLITE_OK, let genStmt
        else {
            return CLIParseOutcome(entries: [], isComplete: false)
        }
        sqlite3_bind_int(genStmt, 1, mapLimit)
        var mappedCount = 0
        var mapBudgetExceeded = false
        while true {
            let step = sqlite3_step(genStmt)
            if step == SQLITE_ROW {
                guard let ptr = sqlite3_column_blob(genStmt, 0) else { continue }
                let count = Int(sqlite3_column_bytes(genStmt, 0))
                if count <= 0 || count > self.maxBytesPerBlob { isComplete = false; continue }
                if totalBytes + count > self
                    .maxTotalBytesPerDatabase { mapBudgetExceeded = true; isComplete = false; break }
                totalBytes += count
                mappedCount += 1
                if mappedCount > self.maxBlobsPerDatabase { isComplete = false; break }
                let blob = Array(UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: UInt8.self), count: count))
                guard let chatModel = AntigravityProtoReader.messageField(blob, field: 1) else { continue }
                let label = AntigravityProtoReader.stringField(chatModel, field: 21)
                let model = AntigravityProtoReader.stringField(chatModel, field: 19)
                if let model, let label {
                    let canon = self.normalizeModelID(model)
                    if let existing = labelToModel[label],
                       existing != canon { labelToModel[label] = "" } else { labelToModel[label] = canon }
                }
            } else if step == SQLITE_DONE { break } else { isComplete = false; break }
        }
        sqlite3_finalize(genStmt)
        if mapBudgetExceeded || mappedCount > self.maxBlobsPerDatabase {
            return CLIParseOutcome(entries: [], isComplete: false)
        }
        if mappedCount == self.maxBlobsPerDatabase + 1 { isComplete = false; return CLIParseOutcome(
            entries: [],
            isComplete: false) }
        totalBytes = 0
        var procStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM gen_metadata ORDER BY idx LIMIT ?", -1, &procStmt, nil) ==
            SQLITE_OK, let procStmt
        else {
            return CLIParseOutcome(entries: [], isComplete: false)
        }
        sqlite3_bind_int(procStmt, 1, mapLimit)
        var processedCount = 0
        while true {
            let step = sqlite3_step(procStmt)
            if step == SQLITE_ROW {
                guard let ptr = sqlite3_column_blob(procStmt, 0) else { continue }
                let count = Int(sqlite3_column_bytes(procStmt, 0))
                if count <= 0 || count > self.maxBytesPerBlob { isComplete = false; continue }
                if totalBytes + count > self.maxTotalBytesPerDatabase { isComplete = false; break }
                totalBytes += count
                processedCount += 1
                if processedCount > self.maxBlobsPerDatabase { isComplete = false; break }
                let blob = Array(UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: UInt8.self), count: count))
                guard let chatModel = AntigravityProtoReader.messageField(blob, field: 1),
                      let usage = AntigravityProtoReader.messageField(chatModel, field: 4) else { continue }
                /// Validate token fields strictly (reject if varint exceeds Int.max)
                func token(_ field: Int, defaultZero: Bool = true) -> Int? {
                    if let v = AntigravityProtoReader.varintField(usage, field: field) {
                        guard let iv = Int(exactly: v) else { return nil }
                        return iv >= 0 ? iv : nil
                    }
                    return defaultZero ? 0 : nil
                }
                guard let sysVal = token(1), let newInVal = token(2), let cacheReadVal = token(5),
                      let outputVal = token(9), let reasoningVal = token(10) else { continue }
                guard let inputTokens = self.checkedAdd(sysVal, newInVal) else { continue }
                guard let t1 = self.checkedAdd(inputTokens, outputVal), let t2 = self.checkedAdd(t1, cacheReadVal),
                      let total = self.checkedAdd(
                          t2,
                          reasoningVal), total != 0 else { continue }
                let totalTokens = total
                if let responseID = AntigravityProtoReader.stringField(usage, field: 11) {
                    if seenResponseIds.contains(responseID) { continue }
                    seenResponseIds.insert(responseID)
                }
                var turnMs: Int64?
                if let gen = AntigravityProtoReader.messageField(chatModel, field: 9),
                   let tsData = AntigravityProtoReader.messageField(
                       gen,
                       field: 4)
                {
                    turnMs = AntigravityProtoReader.protoTimestampMs(tsData)
                }
                let timestampMs: Int64
                if let tm = turnMs {
                    timestampMs = tm
                } else if let sc = sessionCreatedMs {
                    timestampMs = sc
                } else {
                    continue
                }
                let date = self.timestampToDayKey(timestampMs, calendar: calendar)
                let rawModel = AntigravityProtoReader.stringField(chatModel, field: 19) ?? AntigravityProtoReader
                    .stringField(
                        chatModel,
                        field: 21).flatMap { labelToModel[$0]?.isEmpty == false ? labelToModel[$0] : nil } ?? "unknown"
                let modelId = self.normalizeModelID(rawModel)
                if let idx = entries.firstIndex(where: { $0.date == date }) {
                    let e = entries[idx]
                    guard let newInput = self.checkedAdd(e.inputTokens ?? 0, inputTokens),
                          let newOutput = self.checkedAdd(e.outputTokens ?? 0, outputVal),
                          let newCacheRead = self.checkedAdd(e.cacheReadTokens ?? 0, cacheReadVal),
                          let newReason = self.checkedAdd(e.reasoningTokens ?? 0, reasoningVal),
                          let newTotal = self.checkedAdd(e.totalTokens ?? 0, totalTokens)
                    else { isComplete = false; continue }
                    guard let newBreakdown = self.checkedMergeBreakdown(
                        e.modelBreakdowns,
                        model: modelId,
                        tokens: totalTokens,
                        inputTokens: inputTokens,
                        outputTokens: outputVal,
                        cacheReadTokens: cacheReadVal,
                        cacheCreationTokens: 0,
                        reasoningTokens: reasoningVal) else { isComplete = false; continue }
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
                    let e = CostUsageDailyReport.Entry(
                        date: date,
                        inputTokens: inputTokens,
                        outputTokens: outputVal,
                        cacheReadTokens: cacheReadVal,
                        cacheCreationTokens: 0,
                        reasoningTokens: reasoningVal,
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
                            outputTokens: outputVal,
                            cacheReadTokens: cacheReadVal,
                            cacheCreationTokens: 0,
                            reasoningTokens: reasoningVal)])
                    entries.append(e)
                }
            } else if step == SQLITE_DONE { break } else { isComplete = false; break }
        }
        sqlite3_finalize(procStmt)
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
              let total = self.checkedAdd(existing.totalTokens ?? 0, new.totalTokens ?? 0) else { return nil }
        let breakdowns: [CostUsageDailyReport.ModelBreakdown]?
        if let ex = existing.modelBreakdowns, let nw = new.modelBreakdowns {
            var merged = ex
            for b in nw {
                guard let updated = self.checkedMergeBreakdown(
                    merged,
                    model: b.modelName,
                    tokens: b.totalTokens ?? 0,
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
            requestCount: (existing.requestCount ?? 0) + (new.requestCount ?? 0),
            costUSD: nil,
            modelsUsed: nil,
            modelBreakdowns: breakdowns)
    }

    static func makeDailyReport(calendar: Calendar = .current) -> CostUsageDailyReport {
        let dbOutcome = self.parseCLIDBsWithStatus(calendar: calendar)
        let entries: [CostUsageDailyReport.Entry]
        if dbOutcome.isComplete, !dbOutcome.entries.isEmpty {
            entries = dbOutcome.entries
        } else if dbOutcome.isComplete, dbOutcome.entries.isEmpty {
            entries = self.parseJSONLCache(calendar: calendar)
        } else {
            let jsonl = self.parseJSONLCache(calendar: calendar)
            entries = jsonl.isEmpty ? dbOutcome.entries : jsonl
        }
        let sorted = entries.sorted { $0.date < $1.date }
        var totalTokens = 0
        var overflowed = false
        for e in sorted {
            if let t = e.totalTokens {
                let (res, overflow) = totalTokens.addingReportingOverflow(t)
                if overflow { overflowed = true; totalTokens = Int.max; break }
                totalTokens = res
            }
        }
        let summaryTotal: Int? = sorted.isEmpty ? nil : (overflowed ? Int.max : totalTokens)
        let summary: CostUsageDailyReport.Summary? = sorted.isEmpty ? nil : .init(
            totalInputTokens: nil,
            totalOutputTokens: nil,
            totalTokens: summaryTotal,
            totalCostUSD: nil)
        return CostUsageDailyReport(data: sorted, summary: summary)
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
                  let newInput = self.checkedAdd(b.inputTokens ?? 0, inputTokens ?? 0),
                  let newOutput = self.checkedAdd(b.outputTokens ?? 0, outputTokens ?? 0),
                  let newRead = self.checkedAdd(b.cacheReadTokens ?? 0, cacheReadTokens ?? 0),
                  let newCreate = self.checkedAdd(b.cacheCreationTokens ?? 0, cacheCreationTokens ?? 0),
                  let newReason = self.checkedAdd(b.reasoningTokens ?? 0, reasoningTokens ?? 0) else { return nil }
            arr[i] = CostUsageDailyReport.ModelBreakdown(
                modelName: b.modelName,
                costUSD: nil,
                totalTokens: newTotal,
                requestCount: (b.requestCount ?? 0) + 1,
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
                requestCount: 1,
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

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt32 = 0
        var byteCount = 0
        while self.offset < self.bytes.count {
            let byte = self.bytes[self.offset]
            self.offset += 1
            byteCount += 1
            if byteCount == 10 {
                if (byte & 0x80) != 0 { return nil }
                if (byte & 0x7F) > 1 { return nil }
            }
            let payload = UInt64(byte & 0x7F)
            if shift >= 64 { return nil }
            if shift == 63, payload > 1 { return nil }
            result |= payload << shift
            if (byte & 0x80) == 0 { return result }
            shift += 7
            if shift >= 64 { return nil }
            if byteCount >= 10 { return nil }
        }
        return nil
    }

    mutating func nextField() -> (fieldNumber: Int, wireType: Int, data: [UInt8]?, varintValue: UInt64?)? {
        guard self.offset < self.bytes.count else { return nil }
        guard let tag = self.readVarint() else { return nil }
        guard tag <= UInt64(Int.max) else { return nil }
        let fieldNumber = Int(tag >> 3)
        let wireType = Int(tag & 0x07)
        switch wireType {
        case 0:
            guard let val = self.readVarint() else { return nil }
            return (fieldNumber, wireType, nil, val)
        case 1:
            guard let end = self.offset.addingReportingOverflow(8).overflow ? nil : self.offset + 8,
                  end <= self.bytes.count else { return nil }
            let slice = Array(self.bytes[self.offset..<end])
            self.offset = end
            return (fieldNumber, wireType, slice, nil)
        case 2:
            guard let length = self.readVarint(),
                  let len = Int(exactly: length), len >= 0,
                  let end = self.offset.addingReportingOverflow(len).overflow ? nil : self.offset + len,
                  end <= self.bytes.count
            else { return nil }
            let slice = Array(self.bytes[self.offset..<end])
            self.offset = end
            return (fieldNumber, wireType, slice, nil)
        case 5:
            guard let end = self.offset.addingReportingOverflow(4).overflow ? nil : self.offset + 4,
                  end <= self.bytes.count else { return nil }
            let slice = Array(self.bytes[self.offset..<end])
            self.offset = end
            return (fieldNumber, wireType, slice, nil)
        default:
            return nil
        }
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
