@testable import CodexBar
import XCTest

@MainActor
final class ActiveApplicationProviderDetectorTests: XCTestCase {
    // MARK: - provider(for:) Tests

    func testProviderForKnownJetBrainsBundleIdentifiers() {
        let detector = ActiveApplicationProviderDetector(observeApplicationChanges: false)

        let bundleIDs: [String] = [
            "com.jetbrains.intellij",
            "com.jetbrains.CLion",
            "com.jetbrains.AppCode",
            "com.jetbrains.GoLand",
            "com.jetbrains.DataGrip",
            "com.jetbrains.Rider",
            "com.jetbrains.PyCharm",
            "com.jetbrains.WebStorm",
            "com.jetbrains.PhpStorm",
            "com.jetbrains.RubyMine",
            "com.jetbrains.idea",
        ]

        for bundleID in bundleIDs {
            let provider = detector.provider(for: bundleID)
            XCTAssertEqual(provider, .jetbrains, "Bundle ID \(bundleID) should map to .jetbrains")
        }
    }

    func testProviderForKnownCursorBundleIdentifier() {
        let detector = ActiveApplicationProviderDetector(observeApplicationChanges: false)

        let provider = detector.provider(for: "com.cursorcursor.cursor")
        XCTAssertEqual(provider, .cursor)
    }

    func testProviderForUnknownBundleIdentifierReturnsNil() {
        let detector = ActiveApplicationProviderDetector(observeApplicationChanges: false)

        let unknownBundleIDs = [
            "com.apple.Safari",
            "com.apple.Terminal",
            "com.microsoft.VSCode",
            "com.sublimetext.4",
            "com.google.Chrome",
        ]

        for bundleID in unknownBundleIDs {
            let provider = detector.provider(for: bundleID)
            XCTAssertNil(provider, "Unknown bundle ID \(bundleID) should return nil")
        }
    }

    func testProviderForNilBundleIdentifierReturnsNil() {
        let detector = ActiveApplicationProviderDetector(observeApplicationChanges: false)

        let provider = detector.provider(for: nil)
        XCTAssertNil(provider)
    }

    func testProviderForEmptyBundleIdentifierReturnsNil() {
        let detector = ActiveApplicationProviderDetector(observeApplicationChanges: false)

        let provider = detector.provider(for: "")
        XCTAssertNil(provider)
    }

    // MARK: - VS Code Ambiguity Documentation

    func testVSCodeIsNotMapped() {
        // VS Code is intentionally not mapped because it can be used with multiple providers:
        // Copilot, Codex, OpenAI, and others. The mapping would be ambiguous.
        let detector = ActiveApplicationProviderDetector(observeApplicationChanges: false)

        let provider = detector.provider(for: "com.microsoft.VSCode")
        XCTAssertNil(provider, "VS Code should not be mapped to any provider due to ambiguity")
    }

    // MARK: - Xcode Not Mapped Documentation

    func testXcodeIsNotMapped() {
        // Xcode is not mapped because it is not a provider-specific IDE.
        // Users may use Claude via Xcode extension, but the mapping would be too ambiguous.
        let detector = ActiveApplicationProviderDetector(observeApplicationChanges: false)

        let provider = detector.provider(for: "com.apple.dt.Xcode")
        XCTAssertNil(provider, "Xcode should not be mapped to any provider")
    }
}