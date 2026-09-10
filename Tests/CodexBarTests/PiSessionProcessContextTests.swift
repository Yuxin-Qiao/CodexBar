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
        #expect(roots.contains { $0.url == piRoot.standardizedFileURL && $0.preserveAfterProcessExit })
        #expect(roots.contains { $0.url == ompRoot.standardizedFileURL && $0.preserveAfterProcessExit })
        let defaultPiRoot = env.root
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .standardizedFileURL
        #expect(roots.contains {
            $0.url == defaultPiRoot && $0.missingIsKnownEmpty && !$0.preserveAfterProcessExit
        })
    }

    @Test
    func `pi cost roots preserve whitespace in live session selectors`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let project = env.root.appendingPathComponent("pi-project", isDirectory: true)
        let explicitRoot = env.root.appendingPathComponent("pi sessions", isDirectory: true)
        try [project, explicitRoot].forEach {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }

        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": env.root.path],
            baseDirectories: [project],
            processContexts: [
                PiSessionProcessContext(
                    command: "/usr/local/bin/pi --session-dir \(explicitRoot.path)",
                    arguments: ["/usr/local/bin/pi", "--session-dir", explicitRoot.path],
                    workingDirectory: project),
            ])

        #expect(roots.contains { $0.url == explicitRoot.standardizedFileURL && $0.resolutionIsComplete })
        #expect(!roots
            .contains { $0.url.path == explicitRoot.deletingLastPathComponent().appendingPathComponent("pi").path })
    }

    @Test
    func `pi cost cache drops superseded configured roots`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let firstRoot = env.root.appendingPathComponent("configured-first", isDirectory: true)
        let secondRoot = env.root.appendingPathComponent("configured-second", isDirectory: true)
        try [firstRoot, secondRoot].forEach {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }

        func writeAssistant(to root: URL, input: Int, output: Int, name: String) throws {
            let entry: [String: Any] = [
                "type": "message",
                "timestamp": env.isoString(for: day),
                "message": [
                    "role": "assistant",
                    "provider": "openai-codex",
                    "model": "gpt-5.4",
                    "timestamp": Int(day.timeIntervalSince1970 * 1000),
                    "usage": ["input": input, "output": output, "totalTokens": input + output],
                ],
            ]
            try env.jsonl([entry]).write(
                to: root.appendingPathComponent("2026-04-08T10-00-00-000Z_" + name + ".jsonl"),
                atomically: true,
                encoding: .utf8)
        }

        try writeAssistant(to: firstRoot, input: 10, output: 5, name: "first")
        try writeAssistant(to: secondRoot, input: 20, output: 10, name: "second")

        func options(environment: [String: String]) -> PiSessionCostScanner.Options {
            PiSessionCostScanner.Options(
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 3600,
                environment: environment)
        }
        let firstEnvironment = [
            "HOME": env.root.path,
            "PI_CODING_AGENT_SESSION_DIR": firstRoot.path,
        ]
        let secondEnvironment = [
            "HOME": env.root.path,
            "PI_CODING_AGENT_SESSION_DIR": secondRoot.path,
        ]

        let first = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options(environment: firstEnvironment))
        #expect(first.data.first?.totalTokens == 15)

        let second = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options(environment: secondEnvironment))
        #expect(second.data.first?.totalTokens == 30)
        #expect(PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot).sessionRootsFingerprint?
            .contains(firstRoot.path) != true)
    }
}
