import Foundation

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
        let base: URL = if let env = ProcessInfo.processInfo.environment["GEMINI_CLI_HOME"], !env.isEmpty {
            URL(fileURLWithPath: env).appendingPathComponent("antigravity-cli/conversations", isDirectory: true)
        } else if let home {
            home.appendingPathComponent(".gemini/antigravity-cli/conversations", isDirectory: true)
        } else {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gemini/antigravity-cli/conversations", isDirectory: true)
        }
        guard let c = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return c
            .filter {
                $0.pathExtension == "db" && !$0.lastPathComponent.hasSuffix("-wal") && !$0.lastPathComponent
                    .hasSuffix("-shm")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func parseJSONLCache(paths: [URL]? = nil) -> [CostUsageDailyReport.Entry] {
        var entries: [CostUsageDailyReport.Entry] = []
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
                    let modelId =
                        (json["modelId"] as? String ?? json["model_id"] as? String ?? sessionModel ?? "unknown")
                    let input = (json["input"] as? Int) ?? 0
                    let output = (json["output"] as? Int) ?? 0
                    let read = (json["cacheRead"] as? Int) ?? (json["cache_read"] as? Int) ?? 0
                    let write = (json["cacheWrite"] as? Int) ?? (json["cache_write"] as? Int) ?? 0
                    let reason = (json["reasoning"] as? Int) ?? 0
                    let ts = (json["timestamp"] as? Int64) ?? (json["timestamp"] as? Int).map(Int64.init) ?? 0
                    let date = self.timestampToDayKey(ts)
                    let total = input + output + read + write
                    if total == 0 { continue }
                    if let idx = entries.firstIndex(where: { $0.date == date }) {
                        var e = entries[idx]
                        let ne = CostUsageDailyReport.Entry(
                            date: e.date,
                            inputTokens: (e.inputTokens ?? 0) + input,
                            outputTokens: (e.outputTokens ?? 0) + output,
                            cacheReadTokens: (e.cacheReadTokens ?? 0) + read,
                            cacheCreationTokens: (e.cacheCreationTokens ?? 0) + write,
                            reasoningTokens: (e.reasoningTokens ?? 0) + reason,
                            totalTokens: (e.totalTokens ?? 0) + total,
                            requestCount: (e.requestCount ?? 0) + 1,
                            costUSD: e.costUSD ?? 0,
                            modelsUsed: nil,
                            modelBreakdowns: self.mergeBreakdown(e.modelBreakdowns, model: modelId, tokens: total))
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
                            costUSD: 0,
                            modelsUsed: nil,
                            modelBreakdowns: [
                                CostUsageDailyReport.ModelBreakdown(
                                    modelName: modelId,
                                    costUSD: 0,
                                    totalTokens: total,
                                    requestCount: 1),
                            ])
                        entries.append(e)
                    }
                }
            }
        }
        return entries.sorted { $0.date < $1.date }
    }

    static func parseCLIDBs() -> [CostUsageDailyReport.Entry] {
        []
    }

    static func makeDailyReport() -> CostUsageDailyReport {
        var merged: [String: CostUsageDailyReport.Entry] = [:]
        for e in self.parseJSONLCache() + self.parseCLIDBs() {
            if var ex = merged[e.date] {
                let ne = CostUsageDailyReport.Entry(
                    date: ex.date,
                    inputTokens: (ex.inputTokens ?? 0) + (e.inputTokens ?? 0),
                    outputTokens: (ex.outputTokens ?? 0) + (e.outputTokens ?? 0),
                    cacheReadTokens: (ex.cacheReadTokens ?? 0) + (e.cacheReadTokens ?? 0),
                    cacheCreationTokens: (ex.cacheCreationTokens ?? 0) + (e.cacheCreationTokens ?? 0),
                    reasoningTokens: (ex.reasoningTokens ?? 0) + (e.reasoningTokens ?? 0),
                    totalTokens: (ex.totalTokens ?? 0) + (e.totalTokens ?? 0),
                    requestCount: (ex.requestCount ?? 0) + (e.requestCount ?? 0),
                    costUSD: (ex.costUSD ?? 0) + (e.costUSD ?? 0),
                    modelsUsed: nil,
                    modelBreakdowns: self.mergeBreakdowns(ex.modelBreakdowns, e.modelBreakdowns))
                merged[e.date] = ne
            } else {
                merged[e.date] = e
            }
        }
        let sorted = merged.values.sorted { $0.date < $1.date }
        let totalCost = sorted.compactMap(\.costUSD).reduce(0, +)
        let totalTokens = sorted.compactMap(\.totalTokens).reduce(0, +)
        let summary: CostUsageDailyReport.Summary? = sorted.isEmpty ? nil : .init(
            totalInputTokens: nil,
            totalOutputTokens: nil,
            totalTokens: totalTokens,
            totalCostUSD: totalCost)
        return CostUsageDailyReport(data: sorted, summary: summary)
    }

    private static func timestampToDayKey(_ ms: Int64) -> String {
        let sec = Double(ms) / 1000.0
        let date = Date(timeIntervalSince1970: sec)
        let c = Calendar.current
        let comps = c.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    private static func mergeBreakdown(
        _ ex: [CostUsageDailyReport.ModelBreakdown]?,
        model: String,
        tokens: Int) -> [CostUsageDailyReport.ModelBreakdown]
    {
        var arr = ex ?? []
        if let i = arr.firstIndex(where: { $0.modelName == model }) {
            let b = arr[i]
            arr[i] = CostUsageDailyReport.ModelBreakdown(
                modelName: b.modelName,
                costUSD: b.costUSD ?? 0,
                totalTokens: (b.totalTokens ?? 0) + tokens,
                requestCount: (b.requestCount ?? 0) + 1)
        } else {
            arr.append(CostUsageDailyReport.ModelBreakdown(
                modelName: model,
                costUSD: 0,
                totalTokens: tokens,
                requestCount: 1))
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
                ex = CostUsageDailyReport.ModelBreakdown(
                    modelName: ex.modelName,
                    costUSD: (ex.costUSD ?? 0) + (m.costUSD ?? 0),
                    totalTokens: (ex.totalTokens ?? 0) + (m.totalTokens ?? 0),
                    requestCount: (ex.requestCount ?? 0) + (m.requestCount ?? 0))
                d[m.modelName] = ex
            } else {
                d[m.modelName] = m
            }
        }
        return d.isEmpty ? nil : Array(d.values)
    }
}
