import Foundation

/// Built-in `LocalHistoryScanning` conformances that wrap the existing per-tool
/// `…SessionScanner.scanCancellable` entry points. Each wrapper is a stateless value; registering
/// one is all that is required to make a tool discoverable through
/// `LocalHistoryScannerRegistry.shared`.
///
/// When adding a new mainstream tool, define a wrapper here (or in its own provider folder) and
/// append it to `LocalHistoryBuiltInScanners.all` — no controller or switch edits needed.
public enum LocalHistoryBuiltInScanners {
    /// All built-in scanners, in stable registration order.
    public static let all: [any LocalHistoryScanning] = {
        var scanners: [any LocalHistoryScanning] = [
            KimiCodeLocalHistoryScanner(),
            GeminiCLILocalHistoryScanner(),
            OpenCodeLocalHistoryScanner(),
            MiniMaxLocalHistoryScanner(),
            AntigravityLocalHistoryScanner(),
            QwenCodeLocalHistoryScanner(),
            ZcodeLocalHistoryScanner(),
            CopilotLocalHistoryScanner(),
        ]
        #if canImport(SQLite3) || canImport(CSQLite3)
        scanners.append(CursorLocalHistoryScanner())
        scanners.append(TraeLocalHistoryScanner())
        #endif
        return scanners
    }()
}

public struct KimiCodeLocalHistoryScanner: LocalHistoryScanning {
    public init() {}
    public let source: ProviderLocalHistorySource = .kimiCode
    public let displayName = "Kimi Code CLI"
    public let homeEnvironmentKey: String? = "KIMI_CODE_HOME"

    public func homeURL(environment: [String: String]) -> URL? {
        KimiSettingsReader.kimiCodeHomeURL(environment: environment)
    }

    public func scan(context: LocalHistoryScanContext) throws -> CostUsageTokenSnapshot? {
        try KimiCodeSessionScanner.scanCancellable(
            environment: context.environment,
            fileManager: context.fileManager,
            historyDays: context.historyDays,
            now: context.now,
            calendar: context.calendar,
            modelsDevCacheRoot: context.modelsDevCacheRoot,
            checkCancellation: context.checkCancellation)
    }
}

public struct GeminiCLILocalHistoryScanner: LocalHistoryScanning {
    public init() {}
    public let source: ProviderLocalHistorySource = .geminiCLI
    public let displayName = "Gemini CLI"
    public let homeEnvironmentKey: String? = GeminiSessionScanner.cliHomeEnvironmentKey

    public func homeURL(environment: [String: String]) -> URL? {
        GeminiSessionScanner.geminiTmpURL(environment: environment)
    }

    public func scan(context: LocalHistoryScanContext) throws -> CostUsageTokenSnapshot? {
        try GeminiSessionScanner.scanCancellable(
            environment: context.environment,
            fileManager: context.fileManager,
            historyDays: context.historyDays,
            now: context.now,
            calendar: context.calendar,
            checkCancellation: context.checkCancellation)
    }
}

public struct OpenCodeLocalHistoryScanner: LocalHistoryScanning {
    public init() {}
    public let source: ProviderLocalHistorySource = .openCode
    public let displayName = "OpenCode"
    public let homeEnvironmentKey: String? = OpenCodeSessionScanner.dataHomeEnvironmentKey

    public func homeURL(environment: [String: String]) -> URL? {
        OpenCodeSessionScanner.opencodeDatabaseURL(environment: environment)
    }

    public func scan(context: LocalHistoryScanContext) throws -> CostUsageTokenSnapshot? {
        try OpenCodeSessionScanner.scanCancellable(
            environment: context.environment,
            fileManager: context.fileManager,
            historyDays: context.historyDays,
            now: context.now,
            calendar: context.calendar,
            checkCancellation: context.checkCancellation)
    }
}

public struct MiniMaxLocalHistoryScanner: LocalHistoryScanning {
    public init() {}
    public let source: ProviderLocalHistorySource = .miniMax
    public let displayName = "MiniMax Code"
    public let homeEnvironmentKey: String? = MiniMaxSessionScanner.homeEnvironmentKey

    public func homeURL(environment: [String: String]) -> URL? {
        MiniMaxSessionScanner.minimaxHomeURL(environment: environment)
    }

    public func scan(context: LocalHistoryScanContext) throws -> CostUsageTokenSnapshot? {
        try MiniMaxSessionScanner.scanCancellable(
            environment: context.environment,
            historyDays: context.historyDays,
            now: context.now,
            calendar: context.calendar,
            modelsDevCacheRoot: context.modelsDevCacheRoot,
            checkCancellation: context.checkCancellation)
    }
}

public struct AntigravityLocalHistoryScanner: LocalHistoryScanning {
    public init() {}
    public let source: ProviderLocalHistorySource = .antigravity
    public let displayName = "Antigravity"
    public let homeEnvironmentKey: String? = AntigravitySessionScanner.homeEnvironmentKey

    public func homeURL(environment: [String: String]) -> URL? {
        AntigravitySessionScanner.antigravityHomeURL(environment: environment)
    }

    public func scan(context: LocalHistoryScanContext) throws -> CostUsageTokenSnapshot? {
        try AntigravitySessionScanner.scanCancellable(
            environment: context.environment,
            historyDays: context.historyDays,
            now: context.now,
            calendar: context.calendar,
            modelsDevCacheRoot: context.modelsDevCacheRoot,
            checkCancellation: context.checkCancellation)
    }
}

public struct QwenCodeLocalHistoryScanner: LocalHistoryScanning {
    public init() {}
    public let source: ProviderLocalHistorySource = .qwenCode
    public let displayName = "Qwen Code CLI"
    public let homeEnvironmentKey: String? = QwenCodeSessionScanner.homeEnvironmentKey

    public func homeURL(environment: [String: String]) -> URL? {
        QwenCodeSessionScanner.homeURL(environment: environment)
    }

    public func scan(context: LocalHistoryScanContext) throws -> CostUsageTokenSnapshot? {
        try QwenCodeSessionScanner.scanCancellable(
            environment: context.environment,
            fileManager: context.fileManager,
            historyDays: context.historyDays,
            now: context.now,
            calendar: context.calendar,
            modelsDevCacheRoot: context.modelsDevCacheRoot,
            checkCancellation: context.checkCancellation)
    }
}

public struct ZcodeLocalHistoryScanner: LocalHistoryScanning {
    public init() {}
    public let source: ProviderLocalHistorySource = .zcode
    public let displayName = "ZCode"
    public let homeEnvironmentKey: String? = ZcodeSessionScanner.homeEnvironmentKey

    public func homeURL(environment: [String: String]) -> URL? {
        ZcodeSessionScanner.homeURL(environment: environment)
    }

    public func scan(context: LocalHistoryScanContext) throws -> CostUsageTokenSnapshot? {
        try ZcodeSessionScanner.scanCancellable(
            environment: context.environment,
            fileManager: context.fileManager,
            historyDays: context.historyDays,
            now: context.now,
            calendar: context.calendar,
            modelsDevCacheRoot: context.modelsDevCacheRoot,
            checkCancellation: context.checkCancellation)
    }
}

public struct CopilotLocalHistoryScanner: LocalHistoryScanning {
    public init() {}
    public let source: ProviderLocalHistorySource = .copilot
    public let displayName = "GitHub Copilot"
    public let homeEnvironmentKey: String? = CopilotSessionScanner.homeEnvironmentKey

    public func homeURL(environment: [String: String]) -> URL? {
        CopilotSessionScanner.homeURL(environment: environment)
    }

    public func scan(context: LocalHistoryScanContext) throws -> CostUsageTokenSnapshot? {
        try CopilotSessionScanner.scanCancellable(
            environment: context.environment,
            fileManager: context.fileManager,
            historyDays: context.historyDays,
            now: context.now,
            calendar: context.calendar,
            modelsDevCacheRoot: context.modelsDevCacheRoot,
            checkCancellation: context.checkCancellation)
    }
}

#if canImport(SQLite3) || canImport(CSQLite3)
public struct CursorLocalHistoryScanner: LocalHistoryScanning {
    public init() {}
    public let source: ProviderLocalHistorySource = .cursorLocal
    public let displayName = "Cursor"
    public let homeEnvironmentKey: String? = CursorLocalActivityScanner.homeEnvironmentKey

    public func homeURL(environment: [String: String]) -> URL? {
        CursorLocalActivityScanner.databaseURL(environment: environment)
    }

    public func scan(context: LocalHistoryScanContext) throws -> CostUsageTokenSnapshot? {
        try CursorLocalActivityScanner.scanCancellable(
            environment: context.environment,
            historyDays: context.historyDays,
            now: context.now,
            calendar: context.calendar,
            checkCancellation: context.checkCancellation)
    }
}

public struct TraeLocalHistoryScanner: LocalHistoryScanning {
    public init() {}
    public let source: ProviderLocalHistorySource = .traeLocal
    public let displayName = "Trae"
    public let homeEnvironmentKey: String? = TraeLocalActivityScanner.databaseEnvironmentKey

    public func homeURL(environment: [String: String]) -> URL? {
        TraeLocalActivityScanner.databaseURL(environment: environment)
    }

    public func scan(context: LocalHistoryScanContext) throws -> CostUsageTokenSnapshot? {
        try TraeLocalActivityScanner.scanCancellable(
            environment: context.environment,
            fileManager: context.fileManager,
            historyDays: context.historyDays,
            now: context.now,
            calendar: context.calendar,
            checkCancellation: context.checkCancellation)
    }
}
#endif
