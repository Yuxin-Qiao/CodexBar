import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct SpendDashboardExportTests {
    @Test
    func `export filename uses the selected window`() {
        #expect(SpendDashboardJSONExporter.defaultFilename(days: 7) == "codexbar-spend-last-7-days.json")
        #expect(SpendDashboardJSONExporter.defaultFilename(days: 30) == "codexbar-spend-last-30-days.json")
        #expect(
            SpendDashboardJSONExporter.defaultFilename(days: SpendDashboardSource.scanDays)
                == "codexbar-spend-all-time.json")
    }

    @Test
    func `export writes pretty JSON to a file instead of requiring the pasteboard`() throws {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let model = SpendDashboardModel.build(
            inputs: [
                SpendDashboardModel.ProviderInput(
                    id: "cursor",
                    provider: .cursor,
                    displayName: "Cursor",
                    snapshot: CostUsageTokenSnapshot(
                        sessionTokens: 10,
                        sessionCostUSD: 1,
                        last30DaysTokens: 10,
                        last30DaysCostUSD: 1,
                        historyDays: 7,
                        costProvenance: .listPriceEstimate,
                        daily: [
                            CostUsageDailyReport.Entry(
                                date: "2026-07-16",
                                inputTokens: 8,
                                outputTokens: 2,
                                totalTokens: 10,
                                costUSD: 1,
                                modelsUsed: nil,
                                modelBreakdowns: nil),
                        ],
                        updatedAt: now)),
            ],
            requestedDays: 7,
            now: now)
        let data = try SpendDashboardJSONExporter.encodedData(model: model, hiddenSourceIDs: ["cursor"])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpendDashboardExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(SpendDashboardJSONExporter.defaultFilename(days: 7))
        try SpendDashboardJSONExporter.write(data, to: url)

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["requestedDays"] as? Int == 7)
        #expect(object["hiddenSourceIDs"] as? [String] == ["cursor"])
        let json = try #require(String(bytes: data, encoding: .utf8))
        #expect(json.contains("\n"))
        #expect(json.contains("\"provenance\""))
    }
}
