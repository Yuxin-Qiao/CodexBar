import CodexBarCore
import Foundation
import Testing

struct LocalHistoryScannerRegistryTests {
    private struct FakeScanner: LocalHistoryScanning {
        let source: ProviderLocalHistorySource
        let displayName: String
        let homeEnvironmentKey: String? = nil

        func homeURL(environment: [String: String]) -> URL? {
            nil
        }

        func scan(context: LocalHistoryScanContext) throws -> CostUsageTokenSnapshot? {
            nil
        }
    }

    @Test
    func `shared registry registers every built-in source`() {
        let registry = LocalHistoryScannerRegistry.shared
        for source in ProviderLocalHistorySource.builtIn {
            #expect(registry.scanner(for: source) != nil, "missing built-in scanner for \(source.rawValue)")
        }
        #expect(registry.registeredSources.count == ProviderLocalHistorySource.builtIn.count)
    }

    @Test
    func `register adds a new scanner and preserves registration order`() {
        var registry = LocalHistoryScannerRegistry()
        let custom = ProviderLocalHistorySource(rawValue: "customTool")
        #expect(registry.scanner(for: custom) == nil)

        registry.register(FakeScanner(source: custom, displayName: "Custom Tool"))
        #expect(registry.scanner(for: custom)?.displayName == "Custom Tool")
        #expect(registry.registeredSources == [custom])
    }

    @Test
    func `re-registering a source replaces it without duplicating order`() {
        var registry = LocalHistoryScannerRegistry()
        let source = ProviderLocalHistorySource(rawValue: "replaceable")
        registry.register(FakeScanner(source: source, displayName: "First"))
        registry.register(FakeScanner(source: source, displayName: "Second"))

        #expect(registry.scanner(for: source)?.displayName == "Second")
        #expect(registry.registeredSources == [source])
        #expect(registry.all.count == 1)
    }

    @Test
    func `zcode built-in scanner is discoverable with its display name`() {
        let registry = LocalHistoryScannerRegistry.shared
        let scanner = registry.scanner(for: .zcode)
        #expect(scanner?.displayName == "ZCode")
        #expect(scanner?.homeEnvironmentKey == ZcodeSessionScanner.homeEnvironmentKey)
    }
}
