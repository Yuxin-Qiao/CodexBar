import Foundation
import Testing
@testable import CodexBarCore

struct PiProfileResolutionTests {
    @Test
    func `pi provider resolves the selected profile direct sessions layout`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let selectedRoot = env.root
            .appendingPathComponent(".omp", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let unrelatedRoot = env.root
            .appendingPathComponent(".omp", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("personal", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelatedRoot, withIntermediateDirectories: true)

        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: [
                "HOME": env.root.path,
                "OMP_PROFILE": "work",
            ],
            baseDirectory: env.root)

        #expect(roots.contains { $0.url == selectedRoot.standardizedFileURL && $0.resolutionIsComplete })
        #expect(!roots.contains { $0.url == unrelatedRoot.standardizedFileURL })
    }

    @Test
    func `pi provider discovers profiles beneath the configured omp directory`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let selectedRoot = env.root
            .appendingPathComponent(".custom-omp", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let unrelatedRoot = env.root
            .appendingPathComponent(".omp", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("personal", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelatedRoot, withIntermediateDirectories: true)

        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: [
                "HOME": env.root.path,
                "PI_CONFIG_DIR": ".custom-omp",
            ],
            baseDirectory: env.root)

        #expect(roots.contains { $0.url == selectedRoot.standardizedFileURL })
        #expect(!roots.contains { $0.url == unrelatedRoot.standardizedFileURL })
    }
}
