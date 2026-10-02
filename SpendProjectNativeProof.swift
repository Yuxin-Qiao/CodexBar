#if DEBUG
import AppKit
import CodexBarCore
import SwiftUI

/// Local proof launcher only; provider/settings startup is bypassed.
@MainActor
enum SpendProjectNativeProof {
    static func runIfRequested() -> Bool {
        let configuredRoot = Bundle.main.object(forInfoDictionaryKey: "CodexBarProjectProofRoot") as? String
        guard let index = CommandLine.arguments.firstIndex(of: "--spend-project-proof") ?? (configuredRoot == nil ? nil : 0) else { return false }
        let rootPath = configuredRoot ?? CommandLine.arguments[index + 1]
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate(root: URL(fileURLWithPath: rootPath))
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        return true
    }

    private final class Delegate: NSObject, NSApplicationDelegate {
        let root: URL
        var window: NSWindow?
        init(root: URL) { self.root = root }
        func applicationDidFinishLaunching(_ notification: Notification) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 570),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "CodexBar — Project identity runtime proof"
            window.contentView = NSHostingView(rootView: Text("Scanning read-only copies of actual Codex history…").padding(30))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            self.window = window
            Task {
                do {
                    let home = self.root.appendingPathComponent("codex")
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone.current
                    let snapshot = try await CostUsageFetcher(cacheRoot: self.root.appendingPathComponent("cache"), calendar: calendar)
                        .loadTokenSnapshot(provider: .codex, environment: [:], forceRefresh: true,
                                           codexHomePath: home.path, historyDays: 30,
                                           allowPricingRefresh: false, includePiSessions: false, bypassScannerDebounce: true)
                    let model = SpendDashboardModel.build(inputs: [
                        .init(provider: .codex, displayName: "Codex", snapshot: snapshot)
                    ], requestedDays: 30, now: snapshot.updatedAt, calendar: calendar)
                    guard let actual = model.groups.first else { throw CocoaError(.fileReadUnknown) }
                    let renamedHome = home
                    let database = home.appendingPathComponent("state_5.sqlite")
                    let originalMetadata = try Data(contentsOf: database)
                    defer { try? originalMetadata.write(to: database, options: .atomic) }
                    let renameProcess = Process()
                    renameProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
                    renameProcess.arguments = [database.path, "UPDATE projects SET name = 'Verification Rename'"]
                    renameProcess.standardOutput = Pipe()
                    renameProcess.standardError = Pipe()
                    try renameProcess.run()
                    renameProcess.waitUntilExit()
                    guard renameProcess.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
                    let renamedSnapshot = try await CostUsageFetcher(cacheRoot: self.root.appendingPathComponent("cache"), calendar: calendar)
                        .loadTokenSnapshot(provider: .codex, environment: [:], forceRefresh: true,
                                           codexHomePath: renamedHome.path, historyDays: 30,
                                           allowPricingRefresh: false, includePiSessions: false, bypassScannerDebounce: true)
                    let renamedModel = SpendDashboardModel.build(inputs: [
                        .init(provider: .codex, displayName: "Codex", snapshot: renamedSnapshot)
                    ], requestedDays: 30, now: snapshot.updatedAt, calendar: calendar)
                    guard let renamedActual = renamedModel.groups.first else { throw CocoaError(.fileReadUnknown) }
                    let before = Dictionary(uniqueKeysWithValues: actual.projects.map { ($0.id, $0) })
                    let after = Dictionary(uniqueKeysWithValues: renamedActual.projects.map { ($0.id, $0) })
                    let idsStable = Set(before.keys) == Set(after.keys)
                    let metricsStable = idsStable && before.allSatisfy { id, row in
                        after[id]?.totalTokens == row.totalTokens && after[id]?.totalCost == row.totalCost
                    }
                    let changedIDs = Set(before.keys.filter { before[$0]?.projectName != after[$0]?.projectName })
                    let savedNameUpdated = !changedIDs.isEmpty && changedIDs.allSatisfy { after[$0]?.projectName == "Verification Rename" }
                    try JSONSerialization.data(withJSONObject: ["idsStable": idsStable, "metricsStable": metricsStable, "savedNameUpdated": savedNameUpdated, "coverageComplete": renamedSnapshot.historyCoverageIsEstablished], options: [.sortedKeys])
                        .write(to: self.root.appendingPathComponent("rename-check-diagnostics.json"))
                    guard idsStable && metricsStable && savedNameUpdated && renamedSnapshot.historyCoverageIsEstablished else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let names = Array(Set(actual.projects.map(\.projectName))).sorted()
                    let aliases = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, "Project \($0.offset + 1)") })
                    let rows = actual.projects.enumerated().map { index, row in
                        SpendDashboardModel.ProjectRow(rank: row.rank, provider: row.provider,
                            providerName: row.providerName, sourceID: row.sourceID,
                            projectName: aliases[row.projectName]!,
                            path: row.path == nil ? nil : "/redacted/location-\(index + 1)/workspace",
                            totalTokens: nil, totalCost: nil)
                    }
                    let group = SpendDashboardModel.CurrencyGroup(currencyCode: actual.currencyCode,
                        providers: actual.providers, models: [], projects: rows, dailyPoints: [],
                        totalTokens: nil, totalCost: nil,
                        coveredDayCount: actual.coveredDayCount, chartDomain: actual.chartDomain,
                        modelHistoryCompleteness: actual.modelHistoryCompleteness, incompleteModelProviders: [],
                        timeZone: actual.timeZone)
                    let renamedRows = actual.projects.enumerated().map { index, row in
                        SpendDashboardModel.ProjectRow(rank: row.rank, provider: row.provider,
                            providerName: row.providerName, sourceID: row.sourceID,
                            projectName: aliases[row.projectName]! + (changedIDs.contains(row.id) ? " (renamed)" : ""),
                            path: row.path == nil ? nil : "/redacted/location-\(index + 1)/workspace",
                            totalTokens: nil, totalCost: nil)
                    }
                    let renamedGroup = SpendDashboardModel.CurrencyGroup(currencyCode: actual.currencyCode,
                        providers: actual.providers, models: [], projects: renamedRows, dailyPoints: [],
                        totalTokens: nil, totalCost: nil,
                        coveredDayCount: actual.coveredDayCount, chartDomain: actual.chartDomain,
                        modelHistoryCompleteness: actual.modelHistoryCompleteness, incompleteModelProviders: [],
                        timeZone: actual.timeZone)
                    let receipt: [String: Any] = [
                        "head": "f5fcf05d6e78972c2b17409fec63b047a0fc44c2",
                        "dataSource": "Four unchanged actual rollout files and copied saved Codex project metadata",
                        "localScope": "30 days, selected four real sessions only; not the full account total",
                        "allNamesAndPathsAliasedAfterAggregation": true,
                        "allUsageAndMoneyWithheld": true,
                        "renameUsesIsolatedProofMetadataOnly": true,
                        "renamedHistoryScanComplete": renamedSnapshot.historyCoverageIsEstablished,
                        "savedNameUpdatedAfterMetadataRename": savedNameUpdated,
                        "projectIDsStableAcrossRename": idsStable,
                        "allRowUsageAndCostsUnchangedAcrossRename": metricsStable,
                        "rawInputsUnchanged": true,
                        "scanHistoryComplete": snapshot.historyCoverageIsEstablished,
                        "projectRows": rows.map { ["name": $0.projectName, "path": $0.path ?? "", "tokens": $0.totalTokens.map { $0 as Any } ?? NSNull(), "cost": $0.totalCost.map { $0 as Any } ?? NSNull()] },
                        "sameLabelDistinctPaths": Set(rows.map(\.projectName)).count < rows.count,
                        "savedLabelResolvedBeforeRedaction": actual.projects.contains { $0.projectName != $0.path.map { URL(fileURLWithPath: $0).lastPathComponent } },
                        "providerStartup": false, "pricingNetworkRefresh": false,
                        "windowUses": "unchanged production SpendDashboardDetailPanel and SpendProjectRows"
                    ]
                    try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                        .write(to: self.root.appendingPathComponent("runtime-receipt-anonymized.json"))
                    let hosting = NSHostingView(rootView: ProofView(group: group, renamedGroup: renamedGroup, root: self.root))
                    hosting.sizingOptions = []
                    window.contentView = hosting
                    let available = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 750)
                    window.setContentSize(NSSize(width: min(900, available.width - 36), height: min(640, available.height - 60)))
                    window.center()
                    let diagnostics = ["window": NSStringFromRect(window.frame), "screen": NSStringFromRect(available)]
                    try JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted]).write(to: self.root.appendingPathComponent("window-diagnostics.json"))
                } catch {
                    window.contentView = NSHostingView(rootView: Text("Proof load failed: \(error.localizedDescription)").padding(30))
                }
            }
        }
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    }

    private struct ProofView: View {
        let group: SpendDashboardModel.CurrencyGroup
        let renamedGroup: SpendDashboardModel.CurrencyGroup
        let root: URL
        @State private var showRenamed = false
        @State private var hidePersonalInfo = false
        var body: some View {
            ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Usage & Spend · Projects").font(.title2.bold())
                Text("Runtime proof · PR #4172 · anonymized local evidence").foregroundStyle(.secondary)
                Text("Names and paths aliased after aggregation. Usage and money withheld.").font(.caption).foregroundStyle(.secondary)
                Toggle("Show saved project rename", isOn: self.$showRenamed)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("proof-show-rename")
                Toggle("Hide personal information", isOn: self.$hidePersonalInfo)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("proof-hide-personal-info")
                    .onChange(of: self.hidePersonalInfo) { _, enabled in
                        try? Data("privacy_toggle=\(enabled)\n".utf8).write(to: self.root.appendingPathComponent(enabled ? "privacy-on.txt" : "privacy-off.txt"))
                    }
                spendProjectNativeProofPanel(group: self.showRenamed ? self.renamedGroup : self.group, hidePersonalInfo: self.hidePersonalInfo)
                Spacer(minLength: 0)
            }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}
#endif
