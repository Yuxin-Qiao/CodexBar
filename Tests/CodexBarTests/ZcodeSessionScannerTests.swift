import CodexBarCore
import Foundation
import Testing

struct ZcodeSessionScannerTests {
    @Test
    func `scanner reads ZCode rollout usage and normalizes the cached prefix`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZcodeSessionScannerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rollout = root.appendingPathComponent("cli/rollout", isDirectory: true)
        try FileManager.default.createDirectory(at: rollout, withIntermediateDirectories: true)
        // inputTokens includes the cached prefix: input + output == total even with cacheRead > 0.
        // 300 input (of which 200 cached) + 30 output == 330 total → 100 uncached input.
        let inclusive = #"{"completedAt":"2026-07-28T08:01:00.000Z","# +
            #""model":{"modelId":"GLM-5.2","providerId":"builtin:bigmodel-start-plan"},"# +
            #""response":{"usage":{"inputTokens":300,"outputTokens":30,"totalTokens":330,"# +
            #""cacheReadTokens":200,"cacheWriteTokens":0}}}"#
        // A second request on the same day, uncached: input + output == total with no cache.
        let second = #"{"completedAt":"2026-07-28T08:02:00.000Z","# +
            #""model":{"modelId":"GLM-5.2","providerId":"builtin:bigmodel-start-plan"},"# +
            #""response":{"usage":{"inputTokens":30,"outputTokens":7,"totalTokens":37,"# +
            #""cacheReadTokens":0,"cacheWriteTokens":0}}}"#
        let jsonl = [inclusive, second].joined(separator: "\n")
        try Data(jsonl.utf8).write(to: rollout.appendingPathComponent("model-io-sess_abc.jsonl"))

        let snapshot = try #require(ZcodeSessionScanner.scan(
            environment: [ZcodeSessionScanner.homeEnvironmentKey: root.path],
            historyDays: 30,
            now: Date(timeIntervalSince1970: 1_785_283_200),
            calendar: Self.calendar,
            modelsDevCacheRoot: root.appendingPathComponent("pricing-cache", isDirectory: true)))

        #expect(snapshot.historyLabel == "ZCode")
        #expect(snapshot.last30DaysRequests == 2)
        // Uncached input 100 + 30, cache read 200, output 30 + 7 → total 367.
        #expect(snapshot.last30DaysTokens == 367)
        let entry = try #require(snapshot.daily.first)
        #expect(entry.inputTokens == 130)
        #expect(entry.outputTokens == 37)
        #expect(entry.cacheReadTokens == 200)
        #expect(entry.totalTokens == 367)
        let model = try #require(entry.modelBreakdowns?.first)
        // models.dev keys the Z.ai catalog by the lowercase model id.
        #expect(model.modelName == "glm-5.2")
        #expect(model.billingProviderID == UsageProvider.zai.rawValue)
    }

    @Test
    func `scanner treats cache-exclusive input without double counting`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZcodeSessionScannerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rollout = root.appendingPathComponent("cli/rollout", isDirectory: true)
        try FileManager.default.createDirectory(at: rollout, withIntermediateDirectories: true)
        // Defensive: if a build ever reports cache-exclusive input, input + cacheRead + output
        // equals total, so the input is already uncached and must not be reduced again.
        // 100 input + 200 cache + 30 output == 330 total → keep 100 input.
        let exclusive = #"{"completedAt":"2026-07-28T08:01:00.000Z","# +
            #""model":{"modelId":"GLM-5.2","providerId":"builtin:bigmodel-start-plan"},"# +
            #""response":{"usage":{"inputTokens":100,"outputTokens":30,"totalTokens":330,"# +
            #""cacheReadTokens":200,"cacheWriteTokens":0}}}"#
        try Data(exclusive.utf8).write(to: rollout.appendingPathComponent("model-io-sess_def.jsonl"))

        let snapshot = try #require(ZcodeSessionScanner.scan(
            environment: [ZcodeSessionScanner.homeEnvironmentKey: root.path],
            historyDays: 30,
            now: Date(timeIntervalSince1970: 1_785_283_200),
            calendar: Self.calendar,
            modelsDevCacheRoot: root.appendingPathComponent("pricing-cache", isDirectory: true)))

        let entry = try #require(snapshot.daily.first)
        #expect(entry.inputTokens == 100)
        #expect(entry.cacheReadTokens == 200)
        #expect(entry.totalTokens == 330)
    }

    @Test
    func `scanner ignores non-rollout files and cooperatively cancels`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZcodeSessionScannerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rollout = root.appendingPathComponent("cli/rollout", isDirectory: true)
        try FileManager.default.createDirectory(at: rollout, withIntermediateDirectories: true)
        let real = #"{"completedAt":"2026-07-28T08:01:00.000Z","# +
            #""model":{"modelId":"GLM-5.2"},"# +
            #""response":{"usage":{"inputTokens":1,"outputTokens":1,"totalTokens":2}}}"#
        try Data(real.utf8).write(to: rollout.appendingPathComponent("model-io-sess_abc.jsonl"))
        // A decoy that does not match the model-io-sess prefix must be skipped.
        let decoy = #"{"completedAt":"2026-07-28T08:01:00.000Z","# +
            #""response":{"usage":{"inputTokens":999,"outputTokens":999,"totalTokens":1998}}}"#
        try Data(decoy.utf8).write(to: rollout.appendingPathComponent("other.jsonl"))

        var checks = 0
        #expect(throws: CancellationError.self) {
            _ = try ZcodeSessionScanner.scanCancellable(
                environment: [ZcodeSessionScanner.homeEnvironmentKey: root.path],
                historyDays: 30,
                now: Date(timeIntervalSince1970: 1_785_283_200),
                calendar: Self.calendar,
                checkCancellation: {
                    checks += 1
                    if checks >= 2 { throw CancellationError() }
                })
        }

        // Without cancellation, only the rollout file is read.
        let snapshot = try #require(ZcodeSessionScanner.scan(
            environment: [ZcodeSessionScanner.homeEnvironmentKey: root.path],
            historyDays: 30,
            now: Date(timeIntervalSince1970: 1_785_283_200),
            calendar: Self.calendar))
        #expect(snapshot.last30DaysRequests == 1)
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}
