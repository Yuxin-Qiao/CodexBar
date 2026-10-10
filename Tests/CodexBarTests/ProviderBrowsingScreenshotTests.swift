import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

/// Optional native proof of the sidebar with isolated settings and no provider refreshes.
@MainActor
final class ProviderBrowsingScreenshotTests: XCTestCase {
    func test_renderSidebar() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_PROVIDER_BROWSING_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_PROVIDER_BROWSING_SCREENSHOT_DIR to render synthetic sidebar proof.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = testSettingsStore(
            suiteName: "ProviderBrowsingScreenshotTests",
            userDefaults: InMemoryUserDefaults(),
            config: CodexBarConfig(providers: UsageProvider.allCases.map {
                ProviderConfig(
                    id: $0.instanceID,
                    enabled: [.codex, .kimi, .moonshot, .gemini, .antigravity].contains($0))
            }))
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        for language in ["en", "zh-Hans"] {
            try CodexBarLocalizationOverride.$appLanguage.withValue(language) {
                // The upstream row and direct List composition provide a capture reference for selection.
                let reference = List(selection: .constant(SettingsPane.provider(.codex))) {
                    SettingsSidebarProviderRow(provider: .codex, store: store, isEnabled: .constant(true))
                        .tag(SettingsPane.provider(.codex))
                }
                .listStyle(.sidebar)
                .frame(width: 230, height: 100)
                .environment(\.colorScheme, .light)
                .background(Color(nsColor: .windowBackgroundColor))
                let referenceHosting = NSHostingView(rootView: reference)
                referenceHosting.appearance = NSAppearance(named: .aqua)
                let referencePNG = try XCTUnwrap(
                    MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: referenceHosting))
                try referencePNG.write(to: directory.appendingPathComponent("selection-reference-\(language).png"))
                for mode in ProviderListSortMode.allCases {
                    settings.providerListSortMode = mode
                    settings.providersEnabledOnly = false
                    for width in [CGFloat(230), CGFloat(270)] {
                        try self.render(
                            settings: settings,
                            store: store,
                            width: width,
                            directory: directory,
                            name: "sidebar-\(mode.rawValue)-\(language)")
                        XCTAssertEqual(
                            settings.configSnapshot.providers.map(\.id),
                            UsageProvider.allCases.map(\.instanceID))
                    }
                }
                settings.providerListSortMode = .family
                settings.providersEnabledOnly = true
                try self.render(
                    settings: settings,
                    store: store,
                    width: 230,
                    directory: directory,
                    name: "sidebar-family-enabled-\(language)")
                XCTAssertTrue(settings.restoreDefaultProviderOrder())
                try self.render(
                    settings: settings,
                    store: store,
                    width: 230,
                    directory: directory,
                    name: "sidebar-restored-\(language)")
                XCTAssertTrue(settings.undoProviderOrderChange())
                XCTAssertEqual(settings.providerListSortMode, .family)
                XCTAssertEqual(settings.configSnapshot.providers.map(\.id), UsageProvider.allCases.map(\.instanceID))
            }
        }
    }

    private func render(
        settings: SettingsStore,
        store: UsageStore,
        width: CGFloat,
        directory: URL,
        name: String) throws
    {
        let view = SettingsSidebarView(
            settings: settings,
            store: store,
            selection: .constant(.provider(settings.providersEnabledOnly ? .azureopenai : .codex)))
            .frame(width: width, height: 900)
            .environment(\.colorScheme, .light)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .aqua)
        let png = try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
        try png.write(to: directory.appendingPathComponent("\(name)-\(Int(width)).png"))
    }
}
