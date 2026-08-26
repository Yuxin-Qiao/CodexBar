import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

// MARK: - Antigravity Local Reader (tokscale compatible)

enum AntigravityLocalReader {
    static func tokiCachePaths(home: URL? = nil) -> [URL] {
        let base: URL = if let home {
            home.appendingPathComponent(".config/tokscale/antigravity-cache/sessions", isDirectory: true)
        } else if let dir = ProcessInfo.processInfo.environment["TOKSCALE_CONFIG_DIR"] {
            URL(fileURLWithPath: dir).appendingPathComponent("antigravity-cache/sessions", isDirectory: true)
        } else {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/tokscale/antigravity-cache/sessions", isDirectory: true)
        }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return contents.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func cliDBPaths(home: URL? = nil) -> [URL] {
        var roots: [URL] = []
        let baseDir: URL = if let env = ProcessInfo.processInfo.environment["GEMINI_CLI_HOME"], !env.isEmpty {
            URL(fileURLWithPath: env)
        } else if let home {
            home.appendingPathComponent(".gemini", isDirectory: true)
        } else {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gemini", isDirectory: true)
        }

        for name in ["antigravity", "antigravity-cli", "antigravity-ide"] {
            let conv = baseDir.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("conversations", isDirectory: true)
            if FileManager.default.fileExists(atPath: conv.path), !roots.contains(conv) {
                roots.append(conv)
            }
        }

        var dbPaths: [URL] = []
        for root in roots {
            guard let c = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            let filtered = c.filter {
                $0.pathExtension == "db" && !$0.lastPathComponent.hasSuffix("-wal") && !$0.lastPathComponent
                    .hasSuffix("-shm")
            }
            dbPaths.append(contentsOf: filtered)
        }
        return dbPaths.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func normalizeModelID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "unknown" }
        switch trimmed.lowercased() {
        case "gemini-3-flash-a", "gemini-3.6-flash", "gemini-3.6-flash-high", "gemini-3.5-flash-mid",
             "gemini-3-flash-agent":
            return "gemini-3.7-flash"
        case "gemini-pro-default", "gemini-pro-agent", "gemini-3.1-pro":
            return "gemini-2.5-pro"
        default:
            return trimmed
        }
    }

    static func parseJSONLCache(paths: [URL]? = nil, calendar: Calendar = .current) -> [CostUsageDailyReport.Entry] {
        var entries: [CostUsageDailyReport.Entry] = []
        var seenResponseIds = Set<String>()
        for url in paths ?? self.tokiCachePaths() {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            var sessionModel: String?
            for line in text.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, let d = t.data(using: .utf8),
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
                        (json["modelId"] as? String ?? json["model_id"] as? String ?? sessionModel ?? "gemini-2.5-pro")
                    let modelId = self.normalizeModelID(rawModel)
                    let input = (json["input"] as? Int) ?? 0
                    let output = (json["output"] as? Int) ?? 0
                    let read = (json["cacheRead"] as? Int) ?? (json["cache_read"] as? Int) ?? 0
                    let write = (json["cacheWrite"] as? Int) ?? (json["cache_write"] as? Int) ?? 0
                    let reason = (json["reasoning"] as? Int) ?? 0
                    let ts = (json["timestamp"] as? Int64) ?? (json["timestamp"] as? Int).map(Int64.init) ?? 0
                    let date = self.timestampToDayKey(ts, calendar: calendar)
                    let total = input + output + read + write + reason
                    if total == 0 { continue }
                    let cost = CostUsagePricing.claudeCostUSD(
                        model: modelId,
                        inputTokens: input,
                        cacheReadInputTokens: read,
                        cacheCreationInputTokens: write,
                        outputTokens: output + reason)
                    if let idx = entries.firstIndex(where: { $0.date == date }) {
                        var e = entries[idx]
                        let mergedCost: Double? = if e.costUSD == nil, cost == nil {
                            nil
                        } else {
                            (e.costUSD ?? 0) + (cost ?? 0)
                        }
                        let ne = CostUsageDailyReport.Entry(
                            date: e.date,
                            inputTokens: (e.inputTokens ?? 0) + input,
                            outputTokens: (e.outputTokens ?? 0) + output,
                            cacheReadTokens: (e.cacheReadTokens ?? 0) + read,
                            cacheCreationTokens: (e.cacheCreationTokens ?? 0) + write,
                            reasoningTokens: (e.reasoningTokens ?? 0) + reason,
                            totalTokens: (e.totalTokens ?? 0) + total,
                            requestCount: (e.requestCount ?? 0) + 1,
                            costUSD: mergedCost,
                            modelsUsed: nil,
                            modelBreakdowns: self.mergeBreakdown(
                                e.modelBreakdowns,
                                model: modelId,
                                tokens: total,
                                cost: cost,
                                inputTokens: input,
                                outputTokens: output,
                                cacheReadTokens: read,
                                reasoningTokens: reason))
                        entries[idx] = ne
                    } else {
                        let e = CostUsageDailyReport.Entry(
                            date: date,
                            inputTokens: input,
                            outputTokens: output,
                            cacheReadTokens: read,
                            cacheCreationTokens: write,
                            reasoningTokens: reason,
                            totalTokens: total,
                            requestCount: 1,
                            costUSD: cost,
                            modelsUsed: nil,
                            modelBreakdowns: [
                                CostUsageDailyReport.ModelBreakdown(
                                    modelName: modelId,
                                    costUSD: cost,
                                    totalTokens: total,
                                    requestCount: 1,
                                    inputTokens: input,
                                    outputTokens: output,
                                    cacheReadTokens: read,
                                    reasoningTokens: reason),
                            ])
                        entries.append(e)
                    }
                }
            }
        }
        return entries.sorted { $0.date < $1.date }
    }

    // swiftlint:disable:next function_body_length
    static func parseCLIDBs(paths: [URL]? = nil, calendar: Calendar = .current) -> [CostUsageDailyReport.Entry] {
        #if canImport(SQLite3) || canImport(CSQLite3)
        var entries: [CostUsageDailyReport.Entry] = []
        var seenResponseIds = Set<String>()

        for url in paths ?? self.cliDBPaths() {
            var db: OpaquePointer?
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
                continue
            }

            var sessionCreatedMs: Int64?
            var metaStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT data FROM trajectory_metadata_blob LIMIT 1", -1, &metaStmt, nil) ==
                SQLITE_OK,
                let metaStmt
            {
                if sqlite3_step(metaStmt) == SQLITE_ROW,
                   let blobPtr = sqlite3_column_blob(metaStmt, 0)
                {
                    let blobBytes = Int(sqlite3_column_bytes(metaStmt, 0))
                    let blobData = Array(UnsafeBufferPointer(
                        start: blobPtr.assumingMemoryBound(to: UInt8.self),
                        count: blobBytes))
                    if let tsData = AntigravityProtoReader.messageField(blobData, field: 2),
                       let tsMs = AntigravityProtoReader.protoTimestampMs(tsData)
                    {
                        sessionCreatedMs = tsMs
                    }
                }
                sqlite3_finalize(metaStmt)
            }

            let fallbackMs = sessionCreatedMs
                ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map { Int64($0.timeIntervalSince1970 * 1000) }
                ?? Int64(Date().timeIntervalSince1970 * 1000)

            var genStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT data FROM gen_metadata ORDER BY idx", -1, &genStmt, nil) == SQLITE_OK,
                  let genStmt
            else {
                sqlite3_close(db)
                continue
            }

            var blobs: [[UInt8]] = []
            while sqlite3_step(genStmt) == SQLITE_ROW {
                guard let ptr = sqlite3_column_blob(genStmt, 0) else { continue }
                let count = Int(sqlite3_column_bytes(genStmt, 0))
                blobs.append(Array(UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: UInt8.self), count: count)))
            }
            sqlite3_finalize(genStmt)
            sqlite3_close(db)

            var labelToModel: [String: String] = [:]
            var distinctModels: Set<String> = []
            for blob in blobs {
                guard let chatModel = AntigravityProtoReader.messageField(blob, field: 1) else { continue }
                let label = AntigravityProtoReader.stringField(chatModel, field: 21)
                let model = AntigravityProtoReader.stringField(chatModel, field: 19)
                if let model {
                    distinctModels.insert(model)
                    if let label {
                        labelToModel[label] = model
                    }
                }
            }
            let soleModel = distinctModels.count == 1 ? distinctModels.first : nil

            for blob in blobs {
                guard let chatModel = AntigravityProtoReader.messageField(blob, field: 1),
                      let usage = AntigravityProtoReader.messageField(chatModel, field: 4)
                else { continue }

                let systemPrompt = Int(AntigravityProtoReader.varintField(usage, field: 1) ?? 0)
                let newInput = Int(AntigravityProtoReader.varintField(usage, field: 2) ?? 0)
                let inputTokens = systemPrompt + newInput
                let cacheReadTokens = Int(AntigravityProtoReader.varintField(usage, field: 5) ?? 0)
                let outputTokens = Int(AntigravityProtoReader.varintField(usage, field: 9) ?? 0)
                let reasoningTokens = Int(AntigravityProtoReader.varintField(usage, field: 10) ?? 0)

                let total = inputTokens + outputTokens + cacheReadTokens + reasoningTokens
                if total == 0 { continue }

                if let responseID = AntigravityProtoReader.stringField(usage, field: 11) {
                    if seenResponseIds.contains(responseID) { continue }
                    seenResponseIds.insert(responseID)
                }

                var turnMs: Int64?
                if let gen = AntigravityProtoReader.messageField(chatModel, field: 9),
                   let tsData = AntigravityProtoReader.messageField(gen, field: 4)
                {
                    turnMs = AntigravityProtoReader.protoTimestampMs(tsData)
                }
                let timestampMs = turnMs ?? fallbackMs
                let date = self.timestampToDayKey(timestampMs, calendar: calendar)

                let rawModel = AntigravityProtoReader.stringField(chatModel, field: 19)
                    ?? AntigravityProtoReader.stringField(chatModel, field: 21).flatMap { labelToModel[$0] }
                    ?? soleModel
                    ?? "gemini-2.5-pro"
                let modelId = self.normalizeModelID(rawModel)

                let cost = CostUsagePricing.claudeCostUSD(
                    model: modelId,
                    inputTokens: inputTokens,
                    cacheReadInputTokens: cacheReadTokens,
                    cacheCreationInputTokens: 0,
                    outputTokens: outputTokens + reasoningTokens)

                if let idx = entries.firstIndex(where: { $0.date == date }) {
                    var e = entries[idx]
                    let mergedCost: Double? = if e.costUSD == nil, cost == nil {
                        nil
                    } else {
                        (e.costUSD ?? 0) + (cost ?? 0)
                    }
                    let ne = CostUsageDailyReport.Entry(
                        date: e.date,
                        inputTokens: (e.inputTokens ?? 0) + inputTokens,
                        outputTokens: (e.outputTokens ?? 0) + outputTokens,
                        cacheReadTokens: (e.cacheReadTokens ?? 0) + cacheReadTokens,
                        cacheCreationTokens: e.cacheCreationTokens ?? 0,
                        reasoningTokens: (e.reasoningTokens ?? 0) + reasoningTokens,
                        totalTokens: (e.totalTokens ?? 0) + total,
                        requestCount: (e.requestCount ?? 0) + 1,
                        costUSD: mergedCost,
                        modelsUsed: nil,
                        modelBreakdowns: self.mergeBreakdown(
                            e.modelBreakdowns,
                            model: modelId,
                            tokens: total,
                            cost: cost,
                            inputTokens: inputTokens,
                            outputTokens: outputTokens,
                            cacheReadTokens: cacheReadTokens,
                            reasoningTokens: reasoningTokens))
                    entries[idx] = ne
                } else {
                    let e = CostUsageDailyReport.Entry(
                        date: date,
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        cacheReadTokens: cacheReadTokens,
                        cacheCreationTokens: 0,
                        reasoningTokens: reasoningTokens,
                        totalTokens: total,
                        requestCount: 1,
                        costUSD: cost,
                        modelsUsed: nil,
                        modelBreakdowns: [
                            CostUsageDailyReport.ModelBreakdown(
                                modelName: modelId,
                                costUSD: cost,
                                totalTokens: total,
                                requestCount: 1,
                                inputTokens: inputTokens,
                                outputTokens: outputTokens,
                                cacheReadTokens: cacheReadTokens,
                                reasoningTokens: reasoningTokens),
                        ])
                    entries.append(e)
                }
            }
        }
        return entries.sorted { $0.date < $1.date }
        #else
        return []
        #endif
    }

    static func makeDailyReport(calendar: Calendar = .current) -> CostUsageDailyReport {
        var merged: [String: CostUsageDailyReport.Entry] = [:]
        for e in self.parseJSONLCache(calendar: calendar) + self.parseCLIDBs(calendar: calendar) {
            if var ex = merged[e.date] {
                let mergedCost: Double? = if ex.costUSD == nil, e.costUSD == nil {
                    nil
                } else {
                    (ex.costUSD ?? 0) + (e.costUSD ?? 0)
                }
                let ne = CostUsageDailyReport.Entry(
                    date: ex.date,
                    inputTokens: (ex.inputTokens ?? 0) + (e.inputTokens ?? 0),
                    outputTokens: (ex.outputTokens ?? 0) + (e.outputTokens ?? 0),
                    cacheReadTokens: (ex.cacheReadTokens ?? 0) + (e.cacheReadTokens ?? 0),
                    cacheCreationTokens: (ex.cacheCreationTokens ?? 0) + (e.cacheCreationTokens ?? 0),
                    reasoningTokens: (ex.reasoningTokens ?? 0) + (e.reasoningTokens ?? 0),
                    totalTokens: (ex.totalTokens ?? 0) + (e.totalTokens ?? 0),
                    requestCount: (ex.requestCount ?? 0) + (e.requestCount ?? 0),
                    costUSD: mergedCost,
                    modelsUsed: nil,
                    modelBreakdowns: self.mergeBreakdowns(ex.modelBreakdowns, e.modelBreakdowns))
                merged[e.date] = ne
            } else {
                merged[e.date] = e
            }
        }
        let sorted = merged.values.sorted { $0.date < $1.date }
        let costValues = sorted.compactMap(\.costUSD)
        let totalCost: Double? = costValues.isEmpty ? nil : costValues.reduce(0, +)
        let totalTokens = sorted.compactMap(\.totalTokens).reduce(0, +)
        let summary: CostUsageDailyReport.Summary? = sorted.isEmpty ? nil : .init(
            totalInputTokens: nil,
            totalOutputTokens: nil,
            totalTokens: totalTokens,
            totalCostUSD: totalCost)
        return CostUsageDailyReport(data: sorted, summary: summary)
    }

    private static func timestampToDayKey(_ ms: Int64, calendar: Calendar = .current) -> String {
        let sec = Double(ms) / 1000.0
        let date = Date(timeIntervalSince1970: sec)
        let c = calendar
        let comps = c.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    private static func mergeBreakdown(
        _ ex: [CostUsageDailyReport.ModelBreakdown]?,
        model: String,
        tokens: Int,
        cost: Double? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        reasoningTokens: Int? = nil) -> [CostUsageDailyReport.ModelBreakdown]
    {
        var arr = ex ?? []
        if let i = arr.firstIndex(where: { $0.modelName == model }) {
            let b = arr[i]
            let mergedCost: Double? = if b.costUSD == nil, cost == nil {
                nil
            } else {
                (b.costUSD ?? 0) + (cost ?? 0)
            }
            arr[i] = CostUsageDailyReport.ModelBreakdown(
                modelName: b.modelName,
                costUSD: mergedCost,
                totalTokens: (b.totalTokens ?? 0) + tokens,
                requestCount: (b.requestCount ?? 0) + 1,
                inputTokens: (b.inputTokens ?? 0) + (inputTokens ?? 0),
                outputTokens: (b.outputTokens ?? 0) + (outputTokens ?? 0),
                cacheReadTokens: (b.cacheReadTokens ?? 0) + (cacheReadTokens ?? 0),
                reasoningTokens: (b.reasoningTokens ?? 0) + (reasoningTokens ?? 0))
        } else {
            arr.append(CostUsageDailyReport.ModelBreakdown(
                modelName: model,
                costUSD: cost,
                totalTokens: tokens,
                requestCount: 1,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                reasoningTokens: reasoningTokens))
        }
        return arr
    }

    private static func mergeBreakdowns(
        _ a: [CostUsageDailyReport.ModelBreakdown]?,
        _ b: [CostUsageDailyReport.ModelBreakdown]?) -> [CostUsageDailyReport.ModelBreakdown]?
    {
        var d: [String: CostUsageDailyReport.ModelBreakdown] = [:]
        for m in (a ?? []) + (b ?? []) {
            if var ex = d[m.modelName] {
                let mergedCost: Double? = if ex.costUSD == nil, m.costUSD == nil {
                    nil
                } else {
                    (ex.costUSD ?? 0) + (m.costUSD ?? 0)
                }
                ex = CostUsageDailyReport.ModelBreakdown(
                    modelName: ex.modelName,
                    costUSD: mergedCost,
                    totalTokens: (ex.totalTokens ?? 0) + (m.totalTokens ?? 0),
                    requestCount: (ex.requestCount ?? 0) + (m.requestCount ?? 0),
                    inputTokens: (ex.inputTokens ?? 0) + (m.inputTokens ?? 0),
                    outputTokens: (ex.outputTokens ?? 0) + (m.outputTokens ?? 0),
                    cacheReadTokens: (ex.cacheReadTokens ?? 0) + (m.cacheReadTokens ?? 0),
                    reasoningTokens: (ex.reasoningTokens ?? 0) + (m.reasoningTokens ?? 0))
                d[m.modelName] = ex
            } else {
                d[m.modelName] = m
            }
        }
        return d.isEmpty ? nil : Array(d.values)
    }
}

/// Lightweight Protobuf wire-format reader (zero external dependencies).
struct AntigravityProtoReader {
    let bytes: [UInt8]
    var offset: Int = 0

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt32 = 0
        while self.offset < self.bytes.count {
            let byte = self.bytes[self.offset]
            self.offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 {
                return result
            }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    mutating func nextField() -> (fieldNumber: Int, wireType: Int, data: [UInt8]?, varintValue: UInt64?)? {
        guard self.offset < self.bytes.count else { return nil }
        guard let tag = self.readVarint() else { return nil }
        let fieldNumber = Int(tag >> 3)
        let wireType = Int(tag & 0x07)
        switch wireType {
        case 0:
            guard let val = self.readVarint() else { return nil }
            return (fieldNumber, wireType, nil, val)
        case 1:
            guard self.offset + 8 <= self.bytes.count else { return nil }
            let slice = Array(self.bytes[self.offset..<(self.offset + 8)])
            self.offset += 8
            return (fieldNumber, wireType, slice, nil)
        case 2:
            guard let length = self.readVarint() else { return nil }
            let len = Int(length)
            guard len >= 0, self.offset + len <= self.bytes.count else { return nil }
            let slice = Array(self.bytes[self.offset..<(self.offset + len)])
            self.offset += len
            return (fieldNumber, wireType, slice, nil)
        case 5:
            guard self.offset + 4 <= self.bytes.count else { return nil }
            let slice = Array(self.bytes[self.offset..<(self.offset + 4)])
            self.offset += 4
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
        let seconds = Int64(secondsVal)
        let nanos = Int64(nanosVal)
        guard let ms = seconds.checkedMultiply(1000),
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
