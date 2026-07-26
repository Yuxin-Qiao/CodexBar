import Foundation

/// Scans local Gemini CLI session transcripts and folds their per-turn token usage into a
/// token-only `CostUsageTokenSnapshot` for the Usage & Spend dashboard. Same shape as
/// `KimiCodeSessionScanner`; the on-disk semantics mirror tokscale's `sessions/gemini.rs`:
///
/// - Root: `$GEMINI_CLI_HOME/tmp` (default `~/.gemini/tmp`), one `<projectHash>/` dir per project.
/// - Chat recordings: `<projectHash>/chats/session-*.json` (plus legacy `session-*.json` anywhere
///   under `tmp`) holding a `messages` array. Model turns carry `model` and a `tokens` object with
///   `input`/`prompt`, `output`/`candidates`, `cached`, `thoughts`, `tool`, `total` (plus the
///   snake_case/camelCase aliases below) and an RFC 3339 `timestamp` (file mtime is the fallback).
/// - Chat streams: any `*.jsonl` under `tmp`, one message object per line; `init` lines seed the
///   current model for later token lines, and a line whose `id` repeats replaces the earlier one.
///
/// Normalization (mirrors tokscale): when `total` equals input+output+thoughts+tool but not that
/// sum plus cached, the prompt count was cache-inclusive, so the cached overlap is subtracted from
/// input. `tool` tokens fold into input because `CostUsageDailyReport.ModelBreakdown` has no tool
/// bucket. `thoughts` stays folded into billing `outputTokens` (reasoning is part of output for
/// billing) and is additionally surfaced as the `reasoningTokens` sub-bucket. Deliberate deviations:
/// headless `stats` blobs are not parsed, string-typed numbers are rejected, and negative values
/// mark the record corrupt (skipped) rather than clamped — both matching this repo's stricter
/// `KimiCodeSessionScanner` robustness style.
public enum GeminiSessionScanner {
    public static let defaultHistoryDays = 30

    /// Environment override for the Gemini CLI home directory, resolved directly here (the same
    /// way `KimiSettingsReader` honors `KIMI_CODE_HOME`) so this scanner stays self-contained.
    public static let cliHomeEnvironmentKey = "GEMINI_CLI_HOME"

    // MARK: - Wire models

    private struct WireTokens: Decodable {
        let input: Int
        let output: Int
        let cached: Int
        let thoughts: Int
        let tool: Int
        let total: Int?

        private enum CodingKeys: String, CodingKey {
            case input
            case prompt
            case inputTokens = "input_tokens"
            case promptTokens = "prompt_tokens"
            case promptTokenCount
            case output
            case candidates
            case outputTokens = "output_tokens"
            case completionTokens = "completion_tokens"
            case candidatesTokenCount
            case cached
            case cachedTokens = "cached_tokens"
            case cachedContentTokenCount
            case thoughts
            case reasoning
            case thoughtsTokens = "thoughts_tokens"
            case tool
            case toolTokens = "tool_tokens"
            case total
            case totalTokenCount
            case totalTokens = "total_tokens"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.input = Self.first(container, [.input, .prompt, .inputTokens, .promptTokens, .promptTokenCount]) ?? 0
            self.output = Self
                .first(container, [.output, .candidates, .outputTokens, .completionTokens, .candidatesTokenCount]) ?? 0
            self.cached = Self.first(container, [.cached, .cachedTokens, .cachedContentTokenCount]) ?? 0
            self.thoughts = Self.first(container, [.thoughts, .reasoning, .thoughtsTokens]) ?? 0
            self.tool = Self.first(container, [.tool, .toolTokens]) ?? 0
            self.total = Self.first(container, [.total, .totalTokenCount, .totalTokens])
        }

        /// First present, integer-typed alias wins; a missing or mistyped alias falls through.
        private static func first(
            _ container: KeyedDecodingContainer<CodingKeys>,
            _ keys: [CodingKeys]) -> Int?
        {
            for key in keys {
                if let value = try? container.decode(Int.self, forKey: key) {
                    return value
                }
            }
            return nil
        }
    }

    private struct WireMessage: Decodable {
        let id: String?
        let type: String?
        let model: String?
        let tokens: WireTokens?
        let timestamp: Date?

        private enum CodingKeys: String, CodingKey {
            case id
            case type
            case model
            case tokens
            case timestamp
            case createdAt = "created_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try? container.decode(String.self, forKey: .id)
            self.type = try? container.decode(String.self, forKey: .type)
            self.model = try? container.decode(String.self, forKey: .model)
            self.tokens = try? container.decode(WireTokens.self, forKey: .tokens)
            self.timestamp = Self.timestamp(from: container)
        }

        /// Mirrors tokscale: the first *present* key wins; if it is present but unparseable the
        /// caller falls back to the file mtime instead of trying the next key.
        private static func timestamp(from container: KeyedDecodingContainer<CodingKeys>) -> Date? {
            for key in [CodingKeys.timestamp, .createdAt] {
                guard container.contains(key) else { continue }
                if let text = try? container.decode(String.self, forKey: key) {
                    return GeminiSessionScanner.timestampTextDate(text)
                }
                if let number = try? container.decode(Double.self, forKey: key),
                   number.isFinite, number > 0
                {
                    // Milliseconds when the magnitude says so, otherwise seconds (tokscale rule).
                    return Date(timeIntervalSince1970: number >= 1_000_000_000_000 ? number / 1000 : number)
                }
                return nil
            }
            return nil
        }
    }

    private struct WireChatRecording: Decodable {
        let messages: [WireMessage]
    }

    // MARK: - Aggregation

    private struct NormalizedUsage {
        let input: Int
        let output: Int
        let cacheRead: Int
        /// `thoughts` tokens; already included in `output` (billing-inclusive), tracked separately.
        let reasoning: Int
    }

    private struct ResolvedTurn {
        let date: Date
        let model: String
        let usage: NormalizedUsage
    }

    private struct DayModelKey: Hashable {
        let day: String
        let model: String
    }

    private struct TokenAccumulator {
        var input = 0
        var output = 0
        var cacheRead = 0
        var reasoning = 0
        var requests = 0

        mutating func add(_ usage: NormalizedUsage) -> Bool {
            guard let nextInput = Self.adding(self.input, usage.input),
                  let nextOutput = Self.adding(self.output, usage.output),
                  let nextCacheRead = Self.adding(self.cacheRead, usage.cacheRead),
                  let nextReasoning = Self.adding(self.reasoning, usage.reasoning),
                  let nextRequests = Self.adding(self.requests, 1)
            else {
                return false
            }
            self.input = nextInput
            self.output = nextOutput
            self.cacheRead = nextCacheRead
            self.reasoning = nextReasoning
            self.requests = nextRequests
            return true
        }

        mutating func merge(_ other: TokenAccumulator) -> Bool {
            guard let nextInput = Self.adding(self.input, other.input),
                  let nextOutput = Self.adding(self.output, other.output),
                  let nextCacheRead = Self.adding(self.cacheRead, other.cacheRead),
                  let nextReasoning = Self.adding(self.reasoning, other.reasoning),
                  let nextRequests = Self.adding(self.requests, other.requests)
            else {
                return false
            }
            self.input = nextInput
            self.output = nextOutput
            self.cacheRead = nextCacheRead
            self.reasoning = nextReasoning
            self.requests = nextRequests
            return true
        }

        var total: Int? {
            guard let inputAndOutput = Self.adding(self.input, self.output) else { return nil }
            return Self.adding(inputAndOutput, self.cacheRead)
        }

        private static func adding(_ lhs: Int, _ rhs: Int) -> Int? {
            let result = lhs.addingReportingOverflow(rhs)
            return result.overflow ? nil : result.partialValue
        }
    }

    // MARK: - Scanning

    public static func scan(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        historyDays: Int = defaultHistoryDays,
        now: Date = Date(),
        calendar: Calendar = .current) -> CostUsageTokenSnapshot?
    {
        let days = max(1, historyDays)
        let tmp = self.geminiTmpURL(environment: environment)
        guard let enumerator = fileManager.enumerator(
            at: tmp,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else {
            return nil
        }

        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        var values: [DayModelKey: TokenAccumulator] = [:]
        let decoder = JSONDecoder()

        while let url = enumerator.nextObject() as? URL {
            let pathExtension = url.pathExtension.lowercased()
            guard pathExtension == "json" || pathExtension == "jsonl",
                  self.isChatTranscript(url, under: tmp)
            else {
                continue
            }
            let modificationDate = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            if let modificationDate, modificationDate < start {
                continue
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            // Messages without a usable timestamp fall back to the file mtime (tokscale rule);
            // epoch zero simply lands outside the window when even the mtime is unavailable.
            let fallbackDate = modificationDate ?? Date(timeIntervalSince1970: 0)
            let turns = pathExtension == "jsonl"
                ? self.parseStream(data: data, fallbackDate: fallbackDate, decoder: decoder)
                : self.parseChatRecording(data: data, fallbackDate: fallbackDate, decoder: decoder)
            for turn in turns {
                let day = calendar.startOfDay(for: turn.date)
                guard day >= start, day <= end else { continue }
                let key = DayModelKey(day: CostUsageLocalDay.key(from: day, calendar: calendar), model: turn.model)
                var value = values[key] ?? TokenAccumulator()
                guard value.add(turn.usage) else { continue }
                values[key] = value
            }
        }

        guard !values.isEmpty else { return nil }
        let byDay = Dictionary(grouping: values, by: \.key.day)
        let daily = byDay.keys.sorted().compactMap { day -> CostUsageDailyReport.Entry? in
            let models = (byDay[day] ?? []).sorted { lhs, rhs in
                lhs.key.model.localizedCaseInsensitiveCompare(rhs.key.model) == .orderedAscending
            }
            var total = TokenAccumulator()
            var modelBreakdowns: [CostUsageDailyReport.ModelBreakdown] = []
            for (key, value) in models {
                guard let modelTotal = value.total else { return nil }
                guard total.merge(value) else { return nil }
                modelBreakdowns.append(CostUsageDailyReport.ModelBreakdown(
                    modelName: key.model,
                    costUSD: nil,
                    totalTokens: modelTotal,
                    inputTokens: value.input,
                    cacheReadTokens: value.cacheRead,
                    cacheCreationTokens: nil,
                    outputTokens: value.output,
                    reasoningTokens: value.reasoning > 0 ? value.reasoning : nil,
                    requestCount: value.requests))
            }
            guard let totalTokens = total.total else { return nil }
            return CostUsageDailyReport.Entry(
                date: day,
                inputTokens: total.input,
                outputTokens: total.output,
                cacheReadTokens: total.cacheRead,
                cacheCreationTokens: nil,
                totalTokens: totalTokens,
                requestCount: total.requests,
                costUSD: nil,
                modelsUsed: modelBreakdowns.map(\.modelName),
                modelBreakdowns: modelBreakdowns)
        }
        let totalTokens = self.sum(daily.compactMap(\.totalTokens))
        let totalRequests = self.sum(daily.compactMap(\.requestCount))
        guard let totalTokens, let totalRequests else { return nil }

        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            sessionRequests: nil,
            last30DaysTokens: totalTokens,
            last30DaysCostUSD: nil,
            last30DaysRequests: totalRequests,
            currencyCode: "XXX",
            historyDays: days,
            historyCoverageIsEstablished: true,
            historyLabel: "Gemini CLI",
            daily: daily,
            updatedAt: now)
    }

    // MARK: - Parsing

    private static func parseChatRecording(
        data: Data,
        fallbackDate: Date,
        decoder: JSONDecoder) -> [ResolvedTurn]
    {
        guard let recording = try? decoder.decode(WireChatRecording.self, from: data) else { return [] }
        return recording.messages.compactMap { message in
            guard let model = self.cleaned(message.model),
                  let tokens = message.tokens,
                  let usage = self.normalize(tokens)
            else {
                return nil
            }
            return ResolvedTurn(date: message.timestamp ?? fallbackDate, model: model, usage: usage)
        }
    }

    private static func parseStream(
        data: Data,
        fallbackDate: Date,
        decoder: JSONDecoder) -> [ResolvedTurn]
    {
        var turns: [ResolvedTurn] = []
        var indicesByID: [String: Int] = [:]
        var currentModel: String?
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let message = try? decoder.decode(WireMessage.self, from: Data(line)) else { continue }
            if message.type == "init" {
                if let model = self.cleaned(message.model) { currentModel = model }
                continue
            }
            guard message.type == "gemini" || message.tokens != nil else { continue }
            if let model = self.cleaned(message.model) { currentModel = model }
            guard let model = currentModel,
                  let tokens = message.tokens,
                  let usage = self.normalize(tokens)
            else {
                continue
            }
            // A repeated `id` is a streaming rewrite of the same turn: the later line wins.
            let turn = ResolvedTurn(date: message.timestamp ?? fallbackDate, model: model, usage: usage)
            if let id = self.cleaned(message.id) {
                if let index = indicesByID[id] {
                    turns[index] = turn
                } else {
                    indicesByID[id] = turns.count
                    turns.append(turn)
                }
            } else {
                turns.append(turn)
            }
        }
        return turns
    }

    private static func normalize(_ tokens: WireTokens) -> NormalizedUsage? {
        guard tokens.input >= 0, tokens.output >= 0, tokens.cached >= 0,
              tokens.thoughts >= 0, tokens.tool >= 0, tokens.total ?? 0 >= 0
        else {
            return nil
        }

        var input = tokens.input
        if let total = tokens.total, tokens.cached > 0,
           let inclusive = self.sum([tokens.input, tokens.output, tokens.thoughts, tokens.tool]),
           inclusive == total
        {
            // `total` leaving out the cached count proves the input count was cache-inclusive.
            let excludesCache = self.adding(inclusive, tokens.cached).map { $0 != total } ?? true
            if excludesCache {
                input -= min(tokens.cached, input)
            }
        }

        guard let finalInput = self.adding(input, tokens.tool),
              let finalOutput = self.adding(tokens.output, tokens.thoughts)
        else {
            return nil
        }
        return NormalizedUsage(
            input: finalInput,
            output: finalOutput,
            cacheRead: tokens.cached,
            reasoning: tokens.thoughts)
    }

    private static func timestampTextDate(_ text: String) -> Date? {
        guard let trimmed = self.cleaned(text) else { return nil }
        if let date = CostUsageDateParser.parse(trimmed) { return date }
        // Timezone-less ISO-8601 datetimes carry no offset; interpret them as UTC (tokscale rule).
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
        ] {
            if let date = self.utcFormatter(format: format).date(from: trimmed) { return date }
        }
        return nil
    }

    private static func utcFormatter(format: String) -> DateFormatter {
        let key = "GeminiSessionScanner.utcFormatter.\(format)"
        let threadDictionary = Thread.current.threadDictionary
        if let cached = threadDictionary[key] as? DateFormatter { return cached }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        formatter.isLenient = false
        threadDictionary[key] = formatter
        return formatter
    }

    // MARK: - Paths

    public static func geminiTmpURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let override = self.cleaned(environment[self.cliHomeEnvironmentKey]) {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("tmp", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
    }

    /// Mirrors tokscale's layout filter: every `.jsonl` under `tmp` is a candidate chat stream,
    /// while `.json` files need the legacy `session-` prefix or the `tmp/<hash>/chats/` layout.
    private static func isChatTranscript(_ url: URL, under tmp: URL) -> Bool {
        if url.pathExtension.lowercased() == "jsonl" { return true }
        if url.lastPathComponent.hasPrefix("session-") { return true }
        guard let components = self.relativeComponents(of: url, under: tmp) else { return false }
        return components.count == 3 && components[1] == "chats"
    }

    private static func relativeComponents(of url: URL, under base: URL) -> [String]? {
        let baseComponents = base.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.count > baseComponents.count,
              urlComponents.prefix(baseComponents.count).elementsEqual(baseComponents)
        else {
            return nil
        }
        return Array(urlComponents.dropFirst(baseComponents.count))
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func adding(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }

    private static func sum(_ values: [Int]) -> Int? {
        var result = 0
        for value in values {
            let addition = result.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            result = addition.partialValue
        }
        return result
    }
}
