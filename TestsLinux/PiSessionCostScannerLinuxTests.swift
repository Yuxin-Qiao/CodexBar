#if os(Linux)
import Foundation
import Testing
@testable import CodexBarCore

struct PiSessionCostScannerLinuxTests {
    @Test
    func `maps deepseek pi session without network`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-linux-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        let day = Date(timeIntervalSince1970: 1_752_192_000) // 2026-07-10 00:00 UTC
        let iso = ISO8601DateFormatter().string(from: day)
        let entry: [String: Any] = [
            "type": "message",
            "timestamp": iso,
            "message": [
                "role": "assistant",
                "provider": "deepseek",
                "model": "deepseek-chat",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 40,
                    "output": 10,
                    "totalTokens": 50,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: entry)
        let file = sessionsRoot.appendingPathComponent("2026-07-10T00-00-00-000Z_test.jsonl")
        let text = try #require(String(bytes: data, encoding: .utf8))
        try (text + "\n").write(to: file, atomically: true, encoding: .utf8)

        let report = PiSessionCostScanner.loadDailyReport(
            provider: .deepseek,
            since: day,
            until: day,
            now: day,
            options: PiSessionCostScanner.Options(
                piSessionsRoot: sessionsRoot,
                cacheRoot: cacheRoot,
                refreshMinIntervalSeconds: 0))

        #expect(report.data.count == 1)
        #expect(report.data.first?.totalTokens == 50)
        #expect(report.data.first?.modelBreakdowns?.map(\.modelName) == ["deepseek-chat"])
    }
}
#endif
