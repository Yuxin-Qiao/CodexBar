import CodexBarCore
import Foundation
import Testing

struct LocalHistoryScannerRegistryTests {
    @Test
    func `registry contains every built-in source exactly once`() {
        let expected: [ProviderLocalHistorySource] = [
            .antigravity,
            .geminiCLI,
            .kimiCode,
            .miniMax,
            .openCode,
            .qwenCode,
            .zcode,
        ]
        let registered = LocalHistoryScannerRegistry.all.map(\.source)
        #expect(registered.count == expected.count)
        #expect(Set(registered) == Set(expected))
    }

    @Test
    func `scanner lookup resolves built-ins and misses unknown sources`() {
        for source in LocalHistoryScannerRegistry.all.map(\.source) {
            #expect(LocalHistoryScannerRegistry.scanner(for: source) != nil)
        }
        let unknown = ProviderLocalHistorySource(rawValue: "not-a-real-tool")
        #expect(LocalHistoryScannerRegistry.scanner(for: unknown) == nil)
        #expect(LocalHistoryScannerRegistry.homeURL(for: unknown) == nil)
    }

    @Test
    func `home resolution honors each tool's environment override`() {
        let overrideRoot = "/tmp/codexbar-registry-override"

        let gemini = LocalHistoryScannerRegistry.homeURL(
            for: .geminiCLI,
            environment: [GeminiSessionScanner.cliHomeEnvironmentKey: overrideRoot])
        #expect(gemini?.path == overrideRoot)

        let miniMax = LocalHistoryScannerRegistry.homeURL(
            for: .miniMax,
            environment: [MiniMaxSessionScanner.homeEnvironmentKey: overrideRoot])
        #expect(miniMax?.path == overrideRoot)

        let qwen = LocalHistoryScannerRegistry.homeURL(
            for: .qwenCode,
            environment: [QwenCodeSessionScanner.homeEnvironmentKey: overrideRoot])
        #expect(qwen?.path == overrideRoot)

        let zcode = LocalHistoryScannerRegistry.homeURL(
            for: .zcode,
            environment: [ZcodeSessionScanner.homeEnvironmentKey: overrideRoot])
        #expect(zcode?.path == overrideRoot)
    }

    @Test
    func `home resolution falls back to platform defaults without overrides`() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let gemini = LocalHistoryScannerRegistry.homeURL(for: .geminiCLI, environment: [:])
        #expect(gemini?.path == home.appendingPathComponent(".gemini").path)

        let zcode = LocalHistoryScannerRegistry.homeURL(for: .zcode, environment: [:])
        #expect(zcode?.path == home.appendingPathComponent(".zcode/cli").path)
    }

    @Test
    func `blank overrides fall back instead of producing a root path`() {
        let gemini = LocalHistoryScannerRegistry.homeURL(
            for: .geminiCLI,
            environment: [GeminiSessionScanner.cliHomeEnvironmentKey: "   "])
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(gemini?.path == home.appendingPathComponent(".gemini").path)
    }
}
