import Foundation
import Testing
@testable import CodexBarCore

struct PiSharedRootMergeTests {
    @Test
    func `shared pi and omp root keeps required process provenance`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let sharedRoot = env.root
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": env.root.path],
            baseDirectories: [env.root],
            processContexts: [
                PiSessionProcessContext(
                    command: "omp --session-dir \(sharedRoot.path)",
                    workingDirectory: env.root),
            ])

        let root = try #require(roots.first { $0.url == sharedRoot.standardizedFileURL })
        #expect(!root.missingIsKnownEmpty)
        #expect(root.preserveAfterProcessExit)
        #expect(root.retentionKey == "process:omp:session-dir:\(sharedRoot.standardizedFileURL.path)")
    }
}
