import AppKit
import Foundation
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Captures native NSSavePanel proof for Usage & Spend JSON export.
///
/// Run locally (not in CI):
/// ```
/// CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS=1 \
/// CODEXBAR_SPEND_PROOF_DIR=.github/pr-proof \
/// CODEXBAR_LIVE_SAVE_PANEL=1 \
/// swift test --filter SpendDashboardExportLiveProofTests
/// ```
final class SpendDashboardExportLiveProofTests: XCTestCase {
    @MainActor
    func test_nativeSavePanelSaveAndCancelProof() throws {
        guard ProcessInfo.processInfo.environment["CODEXBAR_LIVE_SAVE_PANEL"] == "1" else {
            throw XCTSkip("Set CODEXBAR_LIVE_SAVE_PANEL=1 to capture native NSSavePanel proof.")
        }
        guard let proofDir = ProcessInfo.processInfo.environment["CODEXBAR_SPEND_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_SPEND_PROOF_DIR to write native save-panel proof artifacts.")
        }

        let proofRoot = URL(
            fileURLWithPath: NSString(string: proofDir).expandingTildeInPath,
            isDirectory: true)
        try FileManager.default.createDirectory(at: proofRoot, withIntermediateDirectories: true)

        let saveDirectory = proofRoot.appendingPathComponent("spend-export-native-tmp", isDirectory: true)
        try? FileManager.default.removeItem(at: saveDirectory)
        try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: saveDirectory) }

        let model = Self.fixtureModel()
        let expectedFilename = SpendDashboardJSONExporter.defaultFilename(days: 7)
        let savePanelPNG = proofRoot.appendingPathComponent("spend-export-save-panel.png")
        let cancelPanelPNG = proofRoot.appendingPathComponent("spend-export-cancel-panel.png")
        let nativeSavedJSON = proofRoot.appendingPathComponent("spend-export-native-saved.json")
        let nativeSaveLog = proofRoot.appendingPathComponent("spend-export-native-save.log")
        let nativeCancelLog = proofRoot.appendingPathComponent("spend-export-native-cancel.log")

        try? FileManager.default.removeItem(at: savePanelPNG)
        try? FileManager.default.removeItem(at: cancelPanelPNG)
        try? FileManager.default.removeItem(at: nativeSavedJSON)

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

        let saveExpectation = expectation(description: "native save panel")
        DispatchQueue.global(qos: .userInitiated).async {
            Self.automateSavePanel(
                action: .save,
                destinationDirectory: saveDirectory.path,
                screenshotURL: savePanelPNG)
            saveExpectation.fulfill()
        }

        let saved = SpendDashboardJSONExporter.save(model: model, hiddenSourceIDs: ["cursor"])
        wait(for: [saveExpectation], timeout: 30)
        XCTAssertTrue(saved)

        let savedFile = saveDirectory.appendingPathComponent(expectedFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedFile.path))
        try FileManager.default.copyItem(at: savedFile, to: nativeSavedJSON)

        let saveLog = """
        panel: NSSavePanel
        action: save
        path: \(nativeSavedJSON.path)
        filename: \(expectedFilename)
        screenshot: \(savePanelPNG.lastPathComponent)
        injectedDestination: false
        """
        try saveLog.write(to: nativeSaveLog, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savePanelPNG.path))

        let cancelExpectation = expectation(description: "native cancel panel")
        DispatchQueue.global(qos: .userInitiated).async {
            Self.automateSavePanel(
                action: .cancel,
                destinationDirectory: saveDirectory.path,
                screenshotURL: cancelPanelPNG)
            cancelExpectation.fulfill()
        }

        let cancelled = SpendDashboardJSONExporter.save(model: model, hiddenSourceIDs: [])
        wait(for: [cancelExpectation], timeout: 30)
        XCTAssertFalse(cancelled)

        let cancelContents = try FileManager.default.contentsOfDirectory(atPath: saveDirectory.path)
        XCTAssertEqual(cancelContents, [expectedFilename])

        let cancelLog = """
        panel: NSSavePanel
        action: cancel
        destination: none
        filesCreated: 0
        directoryUnchanged: true
        screenshot: \(cancelPanelPNG.lastPathComponent)
        injectedDestination: false
        """
        try cancelLog.write(to: nativeCancelLog, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cancelPanelPNG.path))

        print("Wrote native save-panel proof to \(proofRoot.path)")
    }

    private enum PanelAction {
        case save
        case cancel
    }

    private nonisolated static func automateSavePanel(
        action: PanelAction,
        destinationDirectory _: String,
        screenshotURL: URL)
    {
        Thread.sleep(forTimeInterval: 1.0)
        self.captureSavePanel(to: screenshotURL)
        switch action {
        case .save:
            _ = self.runAppleScript("""
            tell application "System Events"
                keystroke return
            end tell
            """)
        case .cancel:
            _ = self.runAppleScript("""
            tell application "System Events"
                key code 53
            end tell
            """)
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    private nonisolated static func captureSavePanel(to url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", url.path]
        try? process.run()
        process.waitUntilExit()
    }

    private nonisolated static func runAppleScript(_ source: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private nonisolated static func fixtureModel() -> SpendDashboardModel {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        return SpendDashboardModel.build(
            inputs: [
                SpendDashboardModel.ProviderInput(
                    id: "cursor",
                    provider: .cursor,
                    displayName: "Cursor",
                    snapshot: CostUsageTokenSnapshot(
                        sessionTokens: 10,
                        sessionCostUSD: 1,
                        last30DaysTokens: 10,
                        last30DaysCostUSD: 1,
                        historyDays: 7,
                        costProvenance: .listPriceEstimate,
                        daily: [
                            CostUsageDailyReport.Entry(
                                date: "2026-07-16",
                                inputTokens: 8,
                                outputTokens: 2,
                                totalTokens: 10,
                                costUSD: 1,
                                modelsUsed: nil,
                                modelBreakdowns: nil),
                        ],
                        updatedAt: now)),
            ],
            requestedDays: 7,
            now: now)
    }
}
