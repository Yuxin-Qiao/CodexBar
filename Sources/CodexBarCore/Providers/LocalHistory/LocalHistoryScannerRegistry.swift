import Foundation

/// Registry of local usage-history scanners, keyed by their stable source identifier.
///
/// This replaces per-call-site hardcoding of "which scanner handles which tool". Provider
/// descriptors opt into a source ID via `localHistorySources`; the dashboard resolves that ID to
/// a concrete scanner through this registry. Third-party or future built-in tools register an
/// additional conformance instead of editing the controller.
///
/// The registry is a value type holding type-erased scanners. The process-wide `shared` instance
/// is pre-populated with the built-in scanners; tests can build isolated registries to register
/// fakes.
public struct LocalHistoryScannerRegistry: Sendable {
    private var scannersBySource: [ProviderLocalHistorySource: any LocalHistoryScanning]
    private var insertionOrder: [ProviderLocalHistorySource]

    public init(scanners: [any LocalHistoryScanning] = []) {
        self.scannersBySource = [:]
        self.insertionOrder = []
        for scanner in scanners {
            self.register(scanner)
        }
    }

    /// Registers (or replaces) the scanner for its `source`. Registration order is preserved for
    /// deterministic iteration.
    public mutating func register(_ scanner: any LocalHistoryScanning) {
        if self.scannersBySource[scanner.source] == nil {
            self.insertionOrder.append(scanner.source)
        }
        self.scannersBySource[scanner.source] = scanner
    }

    /// Returns the registered scanner for a source, or `nil` when none is registered.
    public func scanner(for source: ProviderLocalHistorySource) -> (any LocalHistoryScanning)? {
        self.scannersBySource[source]
    }

    /// All registered scanners in registration order.
    public var all: [any LocalHistoryScanning] {
        self.insertionOrder.compactMap { self.scannersBySource[$0] }
    }

    /// Registered source identifiers in registration order.
    public var registeredSources: [ProviderLocalHistorySource] {
        self.insertionOrder
    }
}

extension LocalHistoryScannerRegistry {
    /// Process-wide registry pre-populated with every built-in scanner. The dashboard reads from
    /// this; tests should construct isolated registries instead of mutating shared state.
    public static let shared = LocalHistoryScannerRegistry(
        scanners: LocalHistoryBuiltInScanners.all)
}
