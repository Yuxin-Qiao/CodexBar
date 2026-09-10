import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SettingsStoreTokenCostSourceTests {
    @Test
    func `token cost source detection includes pi and omp roots`() throws {
        let fileManager = FileManager.default

        let piHome = fileManager.temporaryDirectory.appendingPathComponent(
            "pi-token-cost-\(UUID().uuidString)",
            isDirectory: true)
        let piSessions = piHome
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: piSessions, withIntermediateDirectories: true)
        fileManager.createFile(
            atPath: piSessions.appendingPathComponent("session.jsonl").path,
            contents: Data("{}".utf8))
        defer { try? fileManager.removeItem(at: piHome) }

        #expect(SettingsStore.hasAnyTokenCostUsageSources(
            env: ["HOME": piHome.path],
            fileManager: fileManager,
            homeDirectory: piHome))

        let ompHome = fileManager.temporaryDirectory.appendingPathComponent(
            "omp-token-cost-\(UUID().uuidString)",
            isDirectory: true)
        let ompSessions = ompHome
            .appendingPathComponent(".omp", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: ompSessions, withIntermediateDirectories: true)
        fileManager.createFile(
            atPath: ompSessions.appendingPathComponent("session.jsonl").path,
            contents: Data("{}".utf8))
        defer { try? fileManager.removeItem(at: ompHome) }

        #expect(SettingsStore.hasAnyTokenCostUsageSources(
            env: ["HOME": ompHome.path],
            fileManager: fileManager,
            homeDirectory: ompHome))
    }
}
