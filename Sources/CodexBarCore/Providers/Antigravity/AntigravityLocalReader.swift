import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

// MARK: - Antigravity Local Reader (tokscale compatible)

enum AntigravityLocalReader {
    private static let maxBlobsPerDatabase = 10000

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
        let geminiDir = AntigravityOfflineStore.geminiHomeDirectory(home: baseHome, env: env)

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
        return AntigravityStatusSnapshot.canonicalModelID(trimmed)
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
                    let (t1, o1) = input.addingReportingOverflow(output)
                    let (t2, o2) = (o1 ? input : t1).addingReportingOverflow(read)
                    let (t3, o3) = (o2 ? t2 : t2).addingReportingOverflow(write)
                    let (total, o4) = (o3 ? t3 : t3).addingReportingOverflow(reason)
                    if (o4 ? Int.max : total) == 0 { continue }
                    let totalTokens = o4 ? Int.max : total
                    let ts = (json["timestamp"] as? Int64) ?? (json["timestamp"] as? Int).map(Int64.init) ?? 0
                    let date = self.timestampToDayKey(ts, calendar: calendar)

                    if let idx = entries.firstIndex(where: { $0.date == date }) {
                        let e = entries[idx]
                        let ne = CostUsageDailyReport.Entry(
                            date: e.date,
                            inputTokens: (e.inputTokens ?? 0).addingReportingOverflow(input).partialValue,
                            outputTokens: (e.outputTokens ?? 0).addingReportingOverflow(output).partialValue,
                            cacheReadTokens: (e.cacheReadTokens ?? 0).addingReportingOverflow(read).partialValue,
                            cacheCreationTokens: (e.cacheCreationTokens ?? 0).addingReportingOverflow(write)
                                .partialValue,
                            reasoningTokens: (e.reasoningTokens ?? 0).addingReportingOverflow(reason).partialValue,
                            totalTokens: (e.totalTokens ?? 0).addingReportingOverflow(totalTokens).partialValue,
                            requestCount: (e.requestCount ?? 0) + 1,
                            costUSD: nil,
                            modelsUsed: nil,
                            modelBreakdowns: self.mergeBreakdown(
                                e.modelBreakdowns,
                                model: modelId,
                                tokens: totalTokens,
                                inputTokens: input,
                                outputTokens: output,
                                cacheReadTokens: read,
                                cacheCreationTokens: write,
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
                    if blobBytes > 0, blobBytes <= 16 * 1024 * 1024 {
                        let blobData = Array(UnsafeBufferPointer(
                            start: blobPtr.assumingMemoryBound(to: UInt8.self),
                            count: blobBytes))
                        if let tsData = AntigravityProtoReader.messageField(blobData, field: 2),
                           let tsMs = AntigravityProtoReader.protoTimestampMs(tsData)
                        {
                            sessionCreatedMs = tsMs
                        }
                    }
                }
                sqlite3_finalize(metaStmt)
            }

            let fallbackMs = sessionCreatedMs
                ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map { Int64($0.timeIntervalSince1970 * 1000) }
                ?? Int64(Date().timeIntervalSince1970 * 1000)

            var genStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT data FROM gen_metadata ORDER BY idx LIMIT ?", -1, &genStmt, nil) ==
                SQLITE_OK,
                let genStmt
            else {
                sqlite3_close(db)
                continue
            }
            sqlite3_bind_int(genStmt, 1, Int32(self.maxBlobsPerDatabase))

            var blobs: [[UInt8]] = []
            while sqlite3_step(genStmt) == SQLITE_ROW {
                guard let ptr = sqlite3_column_blob(genStmt, 0) else { continue }
                let count = Int(sqlite3_column_bytes(genStmt, 0))
                guard count > 0, count <= 16 * 1024 * 1024 else { continue }
                blobs.append(Array(UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: UInt8.self), count: count)))
            }
            sqlite3_finalize(genStmt)
            sqlite3_close(db)

            var labelToModel: [String: String] = [:]
            for blob in blobs {
                guard let chatModel = AntigravityProtoReader.messageField(blob, field: 1) else { continue }
                let label = AntigravityProtoReader.stringField(chatModel, field: 21)
                let model = AntigravityProtoReader.stringField(chatModel, field: 19)
                if let model, let label {
                    let canon = self.normalizeModelID(model)
                    if let existing = labelToModel[label], existing != canon {
                        labelToModel[label] = ""
                    } else {
                        labelToModel[label] = canon
                    }
                }
            }

            for blob in blobs {
                guard let chatModel = AntigravityProtoReader.messageField(blob, field: 1),
                      let usage = AntigravityProtoReader.messageField(chatModel, field: 4)
                else { continue }

                let systemPrompt = Int(clamping: AntigravityProtoReader.varintField(usage, field: 1) ?? 0)
                let newInput = Int(clamping: AntigravityProtoReader.varintField(usage, field: 2) ?? 0)
                let inputTokens = systemPrompt.addingReportingOverflow(newInput).partialValue
                let cacheReadTokens = Int(clamping: AntigravityProtoReader.varintField(usage, field: 5) ?? 0)
                let outputTokens = Int(clamping: AntigravityProtoReader.varintField(usage, field: 9) ?? 0)
                let reasoningTokens = Int(clamping: AntigravityProtoReader.varintField(usage, field: 10) ?? 0)

                let (t1, o1) = inputTokens.addingReportingOverflow(outputTokens)
                let (t2, o2) = (o1 ? inputTokens : t1).addingReportingOverflow(cacheReadTokens)
                let (total, o3) = (o2 ? t2 : t2).addingReportingOverflow(reasoningTokens)
                if (o3 ? Int.max : total) == 0 { continue }
                let totalTokens = o3 ? Int.max : total

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
                    ?? AntigravityProtoReader.stringField(chatModel, field: 21)
                    .flatMap { labelToModel[$0]?.isEmpty == false ? labelToModel[$0] : nil }
                    ?? "unknown"
                let modelId = self.normalizeModelID(rawModel)

                if let idx = entries.firstIndex(where: { $0.date == date }) {
                    let e = entries[idx]
                    let ne = CostUsageDailyReport.Entry(
                        date: e.date,
                        inputTokens: (e.inputTokens ?? 0).addingReportingOverflow(inputTokens).partialValue,
                        outputTokens: (e.outputTokens ?? 0).addingReportingOverflow(outputTokens).partialValue,
                        cacheReadTokens: (e.cacheReadTokens ?? 0).addingReportingOverflow(cacheReadTokens).partialValue,
                        cacheCreationTokens: e.cacheCreationTokens ?? 0,
                        reasoningTokens: (e.reasoningTokens ?? 0).addingReportingOverflow(reasoningTokens).partialValue,
                        totalTokens: (e.totalTokens ?? 0).addingReportingOverflow(totalTokens).partialValue,
                        requestCount: (e.requestCount ?? 0) + 1,
                        costUSD: nil,
                        modelsUsed: nil,
                        modelBreakdowns: self.mergeBreakdown(
                            e.modelBreakdowns,
                            model: modelId,
                            tokens: totalTokens,
                            inputTokens: inputTokens,
                            outputTokens: outputTokens,
                            cacheReadTokens: cacheReadTokens,
                            cacheCreationTokens: 0,
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
                                inputTokens: inputTokens,
                                outputTokens: outputTokens,
                                cacheReadTokens: cacheReadTokens,
                                cacheCreationTokens: 0,
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
        let dbEntries = self.parseCLIDBs(calendar: calendar)
        let entries = if !dbEntries.isEmpty {
            dbEntries
        } else {
            self.parseJSONLCache(calendar: calendar)
        }
        let sorted = entries.sorted { $0.date < $1.date }
        let totalTokens = sorted.compactMap(\ .totalTokens).reduce(0, +)
        let summary: CostUsageDailyReport.Summary? = sorted.isEmpty ? nil : .init(
            totalInputTokens: nil,
            totalOutputTokens: nil,
            totalTokens: totalTokens,
            totalCostUSD: nil)
        return CostUsageDailyReport(data: sorted, summary: summary)
    }

    private static func timestampToDayKey(_ ms: Int64, calendar: Calendar = .current) -> String {
        let sec = Double(ms) / 1000.0
        let date = Date(timeIntervalSince1970: sec)
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
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
        var arr = ex ?? []
        if let i = arr.firstIndex(where: { $0.modelName == model }) {
            let b = arr[i]
            arr[i] = CostUsageDailyReport.ModelBreakdown(
                modelName: b.modelName,
                costUSD: nil,
                totalTokens: (b.totalTokens ?? 0).addingReportingOverflow(tokens).partialValue,
                requestCount: (b.requestCount ?? 0) + 1,
                inputTokens: (b.inputTokens ?? 0).addingReportingOverflow(inputTokens ?? 0).partialValue,
                outputTokens: (b.outputTokens ?? 0).addingReportingOverflow(outputTokens ?? 0).partialValue,
                cacheReadTokens: (b.cacheReadTokens ?? 0).addingReportingOverflow(cacheReadTokens ?? 0).partialValue,
                cacheCreationTokens: (b.cacheCreationTokens ?? 0).addingReportingOverflow(cacheCreationTokens ?? 0)
                    .partialValue,
                reasoningTokens: (b.reasoningTokens ?? 0).addingReportingOverflow(reasoningTokens ?? 0).partialValue)
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
        let fieldNumber = Int(clamping: tag >> 3)
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
