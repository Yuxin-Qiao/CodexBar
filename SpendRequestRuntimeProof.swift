// ANONYMIZED DERIVATIVE: source labels aliased and proof clock supplied externally.
// Production model and view calls are unchanged. Private inputs and local outputs are not published.
#if DEBUG
import AppKit
import CodexBarCore
import SwiftUI

/// Local verification only. This launcher is removed after building the proof bundles.
@MainActor
enum SpendRequestRuntimeProof {
    static func runIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_REQUEST_PROOF_ROOT"] else { return false }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate(root: URL(fileURLWithPath: path, isDirectory: true))
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        return true
    }

    @MainActor
    private final class Delegate: NSObject, NSApplicationDelegate {
        let root: URL
        var window: NSWindow?
        init(root: URL) { self.root = root }

        func applicationDidFinishLaunching(_ notification: Notification) {
            Task { @MainActor in
                do { try await self.load() } catch {
                    try? Data(String(describing: error).utf8).write(to: self.root.appendingPathComponent("error.txt"))
                    NSApplication.shared.terminate(nil)
                }
            }
        }

        private func load() async throws {
            let output = self.root.appendingPathComponent(ProcessInfo.processInfo.environment["CODEXBAR_REQUEST_PROOF_VARIANT"] ?? "patched")
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            guard let clock = ProcessInfo.processInfo.environment["CODEXBAR_REQUEST_PROOF_NOW"],
                  let timestamp = Double(clock) else {
                throw NSError(domain: "Proof", code: 3, userInfo: [NSLocalizedDescriptionKey: "Set proof clock in Unix seconds"])
            }
            let now = Date(timeIntervalSince1970: timestamp)
            let fetcher = CostUsageFetcher(cacheRoot: output.appendingPathComponent("native-cache"), calendar: calendar)
            _ = try await fetcher.loadTokenSnapshot(
                provider: .codex,
                environment: ["CODEX_HOME": self.root.appendingPathComponent("inputs/codex").path],
                now: now,
                forceRefresh: true,
                codexHomePath: self.root.appendingPathComponent("inputs/codex").path,
                historyDays: 7,
                allowPricingRefresh: false,
                refreshPricingInBackground: false,
                includePiSessions: false,
                bypassScannerDebounce: true,
                calendar: calendar)
            for _ in 0..<20 {
                let status = try await fetcher.advanceCodexScanCatchUp(
                    now: now, codexHomePath: self.root.appendingPathComponent("inputs/codex").path,
                    historyDays: 7, scanDurationPerRefresh: 2, calendar: calendar).value
                if !status.pending { break }
            }
            guard let completed = await fetcher.loadCompletedCodexTokenSnapshotResult(
                now: now, codexHomePath: self.root.appendingPathComponent("inputs/codex").path,
                historyDays: 7, includePiSessions: false, calendar: calendar,
                environment: ["CODEX_HOME": self.root.appendingPathComponent("inputs/codex").path])
            else { throw NSError(domain: "Proof", code: 2, userInfo: [NSLocalizedDescriptionKey: "Native scan not complete"]) }
            let native = completed.snapshot
            let store = OpenCodexUsageStore(cacheRoot: output.appendingPathComponent("opencodex-cache"))
            let known = try store.loadSnapshot(
                logURL: self.root.appendingPathComponent("inputs/opencodex/usage.jsonl"),
                now: now,
                historyDays: 7,
                calendar: calendar)
            let a = SpendDashboardModel.ProviderInput(
                id: "native-codex", provider: .codex, displayName: "Source U", snapshot: native)
            let b = SpendDashboardModel.ProviderInput(
                id: "opencodex", provider: .codex, displayName: "Source K", snapshot: known, sourceKind: .openCodex)
            let inputCases = [[a, b], [a], [b]]
            let labels = ["Mixed sources", "Unavailable requests", "Exact requests"]
            let dayFormatter = DateFormatter()
            dayFormatter.calendar = calendar
            dayFormatter.timeZone = .gmt
            dayFormatter.locale = Locale(identifier: "en_US_POSIX")
            dayFormatter.dateFormat = "yyyy-MM-dd"
            let groups = try inputCases.map { inputs in
                guard let group = SpendDashboardModel.build(
                    inputs: inputs, requestedDays: 7, now: now, calendar: calendar).groups.first
                else { throw NSError(domain: "Proof", code: 1, userInfo: [NSLocalizedDescriptionKey: "No group"]) }
                return group
            }
            let cases = zip(labels, groups).map { label, group in
                ["case": label, "days": group.dailySummaries.map { row in
                    ["day": dayFormatter.string(from: row.day),
                     "requests": row.requestCount as Any? ?? NSNull(),
                     "tokens": row.totalTokens as Any? ?? NSNull(),
                     "cost": row.totalCost as Any? ?? NSNull(),
                     "partialCounts": row.hasPartialCounts,
                     "providers": row.providers.map { source in
                        ["source": source.sourceID, "requests": source.requestCount as Any? ?? NSNull()]
                     }] as [String: Any]
                }] as [String: Any]
            }
            let receipt: [String: Any] = [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "binary": Bundle.main.executableURL?.path ?? "unknown",
                "provenance": "Copied real OpenCodex usage log and one non-forked native Codex session. Bounded sample, not full native history.",
                "nativeCoverageEstablished": native.historyCoverageIsEstablished,
                "nativeScanPartial": native.historyScanIsPartial,
                "opencodexCoverageEstablished": known.historyCoverageIsEstablished,
                "cases": cases,
            ]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("runtime-receipt.json"), options: .atomic)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "CodexBar Requests Verification — " + (ProcessInfo.processInfo.environment["CODEXBAR_REQUEST_PROOF_VARIANT"] ?? "patched")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ProofView(groups: groups, labels: labels))
            self.window = window
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            try Data(String(window.windowNumber).utf8).write(to: output.appendingPathComponent("window-number.txt"))
        }
    }

    @MainActor
    private struct ProofView: View {
        let groups: [SpendDashboardModel.CurrencyGroup]
        let labels: [String]
        @State private var selection = 0
        var body: some View {
            VStack(spacing: 12) {
                Text("Local runtime verification · copied real history · UTC · 7 days").font(.headline)
                Picker("Verification case", selection: self.$selection) {
                    ForEach(0..<self.labels.count, id: \.self) { index in Text(self.labels[index]).tag(index) }
                }.pickerStyle(.segmented)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack {
                            SpendDashboardCurrencySection(group: self.groups[self.selection], requestedDays: 7, hidePersonalInfo: true)
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding(4)
                    }.id(self.selection).onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }.padding(20).preferredColorScheme(.light)
        }
    }
}
#endif
