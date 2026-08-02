import Foundation

struct CodexSpendSnapshotLoadContext: Sendable {
    let account: CodexSpendScanRequest
    let cacheRoot: URL
    let now: Date
    let force: Bool
    let historyDays: Int
    let refreshPricingInBackground: Bool
    let includePiSessions: Bool
    /// Reports Codex full-rescan progress (filesScanned, totalFiles) from the scan queue.
    var progress: (@Sendable (_ scanned: Int, _ total: Int) -> Void)?
}

struct KimiCodeSpendSnapshotLoadContext: Sendable {
    let homePath: String
    let now: Date
    let historyDays: Int
}

struct GeminiSpendSnapshotLoadContext: Sendable {
    let homePath: String
    let now: Date
    let historyDays: Int
}

struct OpenCodeSpendSnapshotLoadContext: Sendable {
    let homePath: String
    let now: Date
    let historyDays: Int
}

struct MiniMaxSpendSnapshotLoadContext: Sendable {
    let homePath: String
    let now: Date
    let historyDays: Int
}

struct AntigravitySpendSnapshotLoadContext: Sendable {
    let homePath: String
    let now: Date
    let historyDays: Int
}

struct QwenCodeSpendSnapshotLoadContext: Sendable {
    let homePath: String
    let now: Date
    let historyDays: Int
}

struct CopilotSpendSnapshotLoadContext: Sendable {
    let homePath: String
    let now: Date
    let historyDays: Int
}
