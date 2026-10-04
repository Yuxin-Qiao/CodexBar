import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Opt-in local proof. Inputs must be copies of existing history, never a live Codex home.
@MainActor
final class SpendDashboardRealHistoryProofTests: XCTestCase {
    func test_copiedHistoryScanAndCachedReload() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_REAL_HISTORY_PROOF_DIR"],
              let mode = environment["CODEXBAR_REAL_HISTORY_PROOF_MODE"]
        else {
            throw XCTSkip("Set a copied-history proof directory and scan/reload mode")
        }
        guard environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1" else {
            return XCTFail("Use the isolated test environment")
        }
        let root = URL(
            fileURLWithPath: path,
            isDirectory: true)
        let home = root.appendingPathComponent("private/copied-home")
        let cache = root.appendingPathComponent("private/cache")
        let nowFile = root.appendingPathComponent("private/now.txt")
        if mode == "scan" {
            XCTAssertFalse(FileManager.default
                .fileExists(atPath: cache.appendingPathComponent("cost-usage/cost-usage.sqlite").path))
            try String(Date().timeIntervalSince1970).write(
                to: nowFile,
                atomically: true,
                encoding: .utf8)
        }
        let now = try Date(timeIntervalSince1970: XCTUnwrap(Double(String(
            contentsOf: nowFile,
            encoding: .utf8))))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        var options = CostUsageScanner.Options(
            codexSessionsRoot: home.appendingPathComponent("sessions"),
            cacheRoot: cache,
            codexTraceDatabaseURL: home.appendingPathComponent("missing-traces.sqlite"),
            calendar: calendar,
            codexScanWorkRecorderForTesting: recorder)
        options.refreshMinIntervalSeconds = 0
        let isolatedEnvironment = ["CODEX_HOME": home.path, "CODEX_SQLITE_HOME": home.path]
        var snapshot: CostUsageTokenSnapshot
        if mode == "scan" {
            snapshot = try await CostUsageFetcher.loadTokenSnapshot(
                provider: .codex,
                environment: isolatedEnvironment,
                now: now,
                forceRefresh: true,
                codexHomePath: home.path,
                historyDays: 7,
                allowPricingRefresh: false,
                includePiSessions: false,
                scannerOptions: options)
            for _ in 0..<12 where !snapshot.historyCoverageIsEstablished || snapshot.historyScanIsPartial {
                snapshot = try await CostUsageFetcher.loadTokenSnapshot(
                    provider: .codex,
                    environment: isolatedEnvironment,
                    now: now,
                    codexHomePath: home.path,
                    historyDays: 7,
                    allowPricingRefresh: false,
                    includePiSessions: false,
                    scannerOptions: options)
            }
            XCTAssertTrue(snapshot.historyCoverageIsEstablished)
            XCTAssertFalse(snapshot.historyScanIsPartial)
        } else {
            XCTAssertEqual(mode, "reload")
            snapshot = try await self.cached(
                home: home,
                now: now,
                options: options,
                environment: isolatedEnvironment)
        }
        XCTAssertFalse(snapshot.projects.isEmpty)
        XCTAssertTrue(snapshot.projects.contains { $0.totalCostUSD != nil })
        XCTAssertTrue(snapshot.projects.contains(where: \.isProjectless))
        XCTAssertTrue(snapshot.projects.contains { !$0.isProjectless })
        let classified = try self.receipt(snapshot)
        let receiptURL = root.appendingPathComponent("private/scan-result.json")
        if mode == "scan" {
            try classified.write(to: receiptURL)
        } else {
            XCTAssertEqual(classified, try Data(contentsOf: receiptURL))
        }
        let stateURL = home.appendingPathComponent(".codex-global-state.json")
        let originalState = try Data(contentsOf: stateURL)
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: originalState) as? [String: Any])
        state["projectless-thread-ids"] = []
        try JSONSerialization.data(withJSONObject: state).write(
            to: stateURL,
            options: .atomic)
        defer { try? originalState.write(
            to: stateURL,
            options: .atomic) }
        let fallback = try await self.cached(
            home: home,
            now: now,
            options: options,
            environment: isolatedEnvironment)
        XCTAssertTrue(fallback.projects.allSatisfy { !$0.isProjectless })
        XCTAssertEqual(try self.accountingDaily(snapshot), try self.accountingDaily(fallback))
        XCTAssertEqual(snapshot.last30DaysTokens, fallback.last30DaysTokens)
        XCTAssertEqual(snapshot.last30DaysCostUSD, fallback.last30DaysCostUSD)
        XCTAssertEqual(snapshot.projects.count, fallback.projects.count)
        for (after, before) in zip(snapshot.projects, fallback.projects) {
            var accounting = after
            accounting.name = before.name
            accounting.isProjectless = false
            XCTAssertEqual(accounting, before)
        }
        try originalState.write(
            to: stateURL,
            options: .atomic)
        let restored = try await self.cached(
            home: home,
            now: now,
            options: options,
            environment: isolatedEnvironment)
        XCTAssertEqual(try self.receipt(restored), classified)
        let model = SpendDashboardModel.build(
            inputs: [.init(
                provider: .codex,
                displayName: "Codex",
                snapshot: snapshot)],
            requestedDays: 7,
            now: now,
            calendar: calendar)
        let group = try XCTUnwrap(model.groups.first)
        let fallbackModel = SpendDashboardModel.build(
            inputs: [.init(provider: .codex, displayName: "Codex", snapshot: fallback)],
            requestedDays: 7, now: now, calendar: calendar)
        let fallbackGroup = try XCTUnwrap(fallbackModel.groups.first)
        XCTAssertEqual(Set(group.projects.map(\.id)), Set(fallbackGroup.projects.map(\.id)))
        let projects = spendDashboardProjectRows(
            group.projects,
            isProjectless: false)
        let chats = spendDashboardProjectRows(
            group.projects,
            isProjectless: true)
        XCTAssertEqual(Set((projects + chats).map(\.id)), Set(group.projects.map(\.id)))
        for row in projects + chats {
            let visible = row.displayIdentity(hidePersonalInfo: false)
            let hidden = row.displayIdentity(hidePersonalInfo: true)
            XCTAssertNil(hidden.path)
            XCTAssertEqual(hidden.name, row.isProjectless ? L("Chat %d", row.rank) : L("Project %d", row.rank))
            XCTAssertEqual(visible, row.displayIdentity(hidePersonalInfo: false))
        }
        if mode == "scan" {
            try self.render(
                group: group,
                root: root,
                section: .projects,
                privacy: false,
                name: "projects")
            try self.render(
                group: group,
                root: root,
                section: .chats,
                privacy: false,
                name: "chats")
            try self.render(
                group: group,
                root: root,
                section: .chats,
                privacy: true,
                name: "privacy")
        }
        let publicReceipt: [String: Any] = [
            "mode": mode, "source": "copied existing desktop history", "completeHistory": true,
            "projectRows": projects.count, "independentChatRows": chats.count,
            "dailyAccountingMatchesMarkerDisabledControl": true,
            "allProjectAccountingAndSourcePathsMatchControl": true,
            "rowIdentitiesPreservedAcrossClassification": true,
            "privacyHidesAllPathsAndUsesNumberedLabels": true,
            "privacyOffRestoresDisplayIdentities": true,
            "metadataRestorationReproducesClassification": true,
            "cachedReloadMatchesFreshScan": mode == "reload",
            "scannerFileAttempts": recorder.snapshot().codexFileScanAttempts,
            "hasPricedProjectRows": snapshot.projects.contains { $0.totalCostUSD != nil },
            "privateValues": "withheld: names, paths, IDs, token counts, amounts",
        ]
        try JSONSerialization.data(
            withJSONObject: publicReceipt,
            options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appendingPathComponent("public/\(mode).json"))
    }

    private func cached(
        home: URL,
        now: Date,
        options: CostUsageScanner.Options,
        environment: [String: String]) async throws -> CostUsageTokenSnapshot
    {
        let result = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: now,
            codexHomePath: home.path,
            historyDays: 7,
            allowScopedCodexHome: true,
            includePiSessions: false,
            requireCompleteHistory: true,
            scannerOptions: options,
            environment: environment)
        return try XCTUnwrap(result?.snapshot)
    }

    private func accountingDaily(_ snapshot: CostUsageTokenSnapshot) throws -> Data {
        let fields: Set = [
            "date",
            "inputTokens",
            "outputTokens",
            "cacheReadTokens",
            "cacheCreationTokens",
            "reasoningTokens",
            "totalTokens",
            "costUSD",
        ]
        let encoded = try JSONEncoder().encode(snapshot.daily)
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        return try JSONSerialization.data(
            withJSONObject: entries.map { $0.filter { fields.contains($0.key) } },
            options: [.sortedKeys])
    }

    private func receipt(_ snapshot: CostUsageTokenSnapshot) throws -> Data {
        let daily = try JSONSerialization.jsonObject(with: self.accountingDaily(snapshot))
        let projects: [[String: Any]] = snapshot.projects.map {
            [
                "path": $0.path as Any? ?? NSNull(),
                "name": $0.name,
                "chat": $0.isProjectless,
                "tokens": $0.totalTokens as Any? ?? NSNull(),
                "cost": $0.totalCostUSD as Any? ?? NSNull(),
                "sourcePaths": $0.sources.compactMap(\.path),
            ]
        }
        return try JSONSerialization.data(
            withJSONObject: ["daily": daily, "projects": projects],
            options: [.sortedKeys])
    }

    private func render(
        group: SpendDashboardModel.CurrencyGroup,
        root: URL,
        section: SpendDashboardDetailSection,
        privacy: Bool,
        name: String) throws
    {
        let view = SpendDashboardCurrencySection(
            group: group,
            requestedDays: 7,
            hidePersonalInfo: privacy,
            initialDetailSection: section)
            .padding(24).frame(width: 920)
            .environment(\.locale, Locale(identifier: "en_US"))
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = CGRect(
            origin: .zero,
            size: hosting.fittingSize)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(
            in: hosting.bounds,
            to: bitmap)
        try XCTUnwrap(bitmap.representation(
            using: .png,
            properties: [:]))
            .write(to: root.appendingPathComponent("private/\(name).png"))
    }
}
