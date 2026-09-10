import Foundation
import Testing
@testable import CodexBarCore

struct PiSessionProcessContextTests {
    @Test
    func `pi cost cache keeps a live process root after the process exits`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 7)
        let project = env.root.appendingPathComponent("live-project", isDirectory: true)
        let liveRoot = env.root.appendingPathComponent("live-session-root", isDirectory: true)
        let defaultRoot = env.root
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try [project, liveRoot, defaultRoot].forEach {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }

        let liveEntry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "openai/gpt-5.4",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": ["input": 3, "output": 2, "totalTokens": 5],
            ],
        ]
        let defaultEntry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "anthropic",
                "model": "claude-sonnet-4-6",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": ["input": 4, "output": 3, "totalTokens": 7],
            ],
        ]
        try env.jsonl([liveEntry]).write(
            to: liveRoot.appendingPathComponent("2026-04-07T10-00-00-000Z_live.jsonl"),
            atomically: true,
            encoding: .utf8)
        try env.jsonl([defaultEntry]).write(
            to: defaultRoot.appendingPathComponent("2026-04-07T10-00-00-000Z_default.jsonl"),
            atomically: true,
            encoding: .utf8)

        let environment = ["HOME": env.root.path]
        let liveContext = PiSessionProcessContext(
            command: "/usr/local/bin/pi --session-dir \(liveRoot.path)",
            workingDirectory: project)
        let first = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .pi,
            environment: environment,
            now: day,
            forceRefresh: true,
            historyDays: 1,
            allowPricingRefresh: false,
            scannerOptions: CostUsageScanner.Options(cacheRoot: env.cacheRoot),
            piScannerOptions: PiSessionCostScanner.Options(
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0,
                environment: environment,
                workingDirectories: [project],
                processContexts: [liveContext]))
        #expect(first.sessionTokens == 12)

        let afterExit = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .pi,
            environment: environment,
            now: day,
            forceRefresh: true,
            historyDays: 1,
            allowPricingRefresh: false,
            scannerOptions: CostUsageScanner.Options(cacheRoot: env.cacheRoot),
            piScannerOptions: PiSessionCostScanner.Options(
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0,
                environment: environment,
                workingDirectories: [project]))
        #expect(afterExit.sessionTokens == 12)
        #expect(afterExit.historyCoverageIsEstablished)
    }

    @Test
    func `pi cost roots carry live process selectors and preserve the default root`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let piProject = env.root.appendingPathComponent("pi-project", isDirectory: true)
        let ompProject = env.root.appendingPathComponent("omp-project", isDirectory: true)
        let piRoot = env.root.appendingPathComponent("pi-process-sessions", isDirectory: true)
        let ompRoot = env.root
            .appendingPathComponent(".omp", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try [piProject, ompProject, piRoot, ompRoot].forEach {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }

        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": env.root.path],
            baseDirectories: [piProject, ompProject],
            processContexts: [
                PiSessionProcessContext(
                    command: "/usr/local/bin/pi --session-dir \(piRoot.path)",
                    workingDirectory: piProject),
                PiSessionProcessContext(
                    command: "/usr/local/bin/omp --profile work",
                    workingDirectory: ompProject),
            ])

        #expect(roots.contains { $0.url == piRoot.standardizedFileURL && $0.resolutionIsComplete })
        #expect(roots.contains { $0.url == ompRoot.standardizedFileURL && $0.resolutionIsComplete })
        let defaultPiRoot = env.root
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .standardizedFileURL
        #expect(roots.contains { $0.url == defaultPiRoot })
    }
}
