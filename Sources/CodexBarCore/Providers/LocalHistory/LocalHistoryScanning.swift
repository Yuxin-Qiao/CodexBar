import Foundation

/// Shared parameters for a local history scan, bundled so scanner signatures stay small and so
/// new scan-wide options can be added without changing every conformance.
///
/// `FileManager` is a reference type that Foundation documents as safe to share across threads
/// for the operations these scanners perform, so the bundle is marked `@unchecked Sendable`.
public struct LocalHistoryScanContext: @unchecked Sendable {
    public var environment: [String: String]
    public var fileManager: FileManager
    public var historyDays: Int
    public var now: Date
    public var calendar: Calendar
    public var modelsDevCacheRoot: URL?
    public var checkCancellation: @Sendable () throws -> Void

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        historyDays: Int = 30,
        now: Date = Date(),
        calendar: Calendar = .current,
        modelsDevCacheRoot: URL? = nil,
        checkCancellation: @escaping @Sendable () throws -> Void = {})
    {
        self.environment = environment
        self.fileManager = fileManager
        self.historyDays = historyDays
        self.now = now
        self.calendar = calendar
        self.modelsDevCacheRoot = modelsDevCacheRoot
        self.checkCancellation = checkCancellation
    }
}

/// A local usage-history scanner for a single tool (CLI/desktop client).
///
/// This is the registerable extension point for the Usage & Spend data layer, modeled on
/// tokscale's `define_clients!` macro: adding support for a new mainstream tool means
/// implementing one `LocalHistoryScanning` conformance and registering it, without editing any
/// central switch or the dashboard controller. A scanner knows how to locate its tool's home
/// directory and how to fold the local files it finds there into a `CostUsageTokenSnapshot`.
///
/// Scanners are value types (usually enums with no cases) that wrap an existing
/// `…SessionScanner.scanCancellable` entry point. They are `Sendable` so the registry can vend
/// them across actor boundaries.
public protocol LocalHistoryScanning: Sendable {
    /// Stable identifier matching the provider descriptor's `localHistorySources` entry.
    var source: ProviderLocalHistorySource { get }

    /// Human-facing tool name shown in the dashboard (e.g. "Kimi Code CLI").
    var displayName: String { get }

    /// Environment variable that overrides the tool's home directory (e.g. `KIMI_CODE_HOME`).
    /// `nil` when the tool has a fixed, non-overridable home.
    var homeEnvironmentKey: String? { get }

    /// Resolves the tool's home directory from the environment, or `nil` when the tool is not
    /// installed / has no local history on this machine.
    func homeURL(environment: [String: String]) -> URL?

    /// Scans the tool's local history and returns a dashboard-ready snapshot, or `nil` when no
    /// usable history exists. Implementations must honor cancellation via the context's
    /// `checkCancellation`.
    func scan(context: LocalHistoryScanContext) throws -> CostUsageTokenSnapshot?
}

extension LocalHistoryScanning {
    /// Convenience for the common case where a scanner simply forwards to an existing
    /// `…SessionScanner.scanCancellable` static method.
    public func scan(environment: [String: String]) throws -> CostUsageTokenSnapshot? {
        try self.scan(context: LocalHistoryScanContext(environment: environment))
    }
}
