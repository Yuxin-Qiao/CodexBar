import AppKit
import CodexBarCore
import CoreGraphics
import Foundation
import XCTest
@testable import CodexBar

/// Opt-in native NSMenu regression proof with synthetic cost data and no provider transports.
@MainActor
final class CostHistoryMetricNativeProofTests: XCTestCase {
    func test_metricSwitchDoesNotScrollNativeMenu() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CODEXBAR_COST_METRIC_NATIVE_PROOF"] == "1" else {
            throw XCTSkip("Set CODEXBAR_COST_METRIC_NATIVE_PROOF=1 to run the native menu proof.")
        }
        guard environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
        else {
            return XCTFail("Native proof requires credential, Keychain, and session isolation.")
        }

        let application = NSApplication.shared
        guard application.delegate == nil, UserDefaults.standard.object(forKey: "NSOpen") == nil else {
            return XCTFail("Native proof requires a standalone test application.")
        }
        let previousPolicy = application.activationPolicy()
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        host.title = "CodexBar Cost Metric Proof"
        host.isReleasedWhenClosed = false
        guard let screen = host.screen ?? NSScreen.main else {
            return XCTFail("Native metric proof requires an attached display.")
        }

        var daily: [CostUsageDailyReport.Entry] = []
        for day in 1...30 {
            let cost = Double(day) * 0.25
            let totalTokens = day * 1200
            let breakdown = CostUsageDailyReport.ModelBreakdown(
                modelName: "fixture-model",
                costUSD: cost,
                totalTokens: totalTokens)
            daily.append(CostUsageDailyReport.Entry(
                date: String(format: "2026-08-%02d", day),
                inputTokens: day * 1000,
                outputTokens: day * 200,
                totalTokens: totalTokens,
                costUSD: cost,
                modelsUsed: ["fixture-model"],
                modelBreakdowns: [breakdown]))
        }
        var projects: [CostUsageProjectBreakdown] = []
        var sessions: [CostUsageSessionBreakdown] = []
        for index in 1...5 {
            var sources: [CostUsageProjectSourceBreakdown] = []
            for sourceIndex in 1...3 {
                let source = CostUsageProjectSourceBreakdown(
                    name: "Fixture source \(sourceIndex)",
                    path: "/tmp/codexbar-cost-proof/source-\(index)-\(sourceIndex)",
                    totalTokens: sourceIndex * 1000,
                    totalCostUSD: Double(sourceIndex),
                    daily: [],
                    modelBreakdowns: nil)
                sources.append(source)
            }
            let project = CostUsageProjectBreakdown(
                name: "Fixture project \(index)",
                path: "/tmp/codexbar-cost-proof/project-\(index)",
                totalTokens: index * 10000,
                totalCostUSD: Double(index),
                daily: [],
                modelBreakdowns: nil,
                sources: sources)
            projects.append(project)

            let lastActivity = Date(timeIntervalSince1970: TimeInterval(index))
            let session = CostUsageSessionBreakdown(
                sessionID: "fixture-session-\(index)",
                lastActivity: lastActivity,
                inputTokens: index * 1000,
                cachedInputTokens: index * 500,
                outputTokens: index * 100,
                totalTokens: index * 1100,
                requestCount: index,
                costUSD: Double(index),
                modelBreakdowns: [])
            sessions.append(session)
        }
        let chart = CostHistoryChartMenuView(
            provider: .codex,
            daily: daily,
            totalCostUSD: daily.reduce(0) { $0 + ($1.costUSD ?? 0) },
            projects: projects,
            sessions: sessions,
            hidePersonalInfo: false,
            width: 400)
        let hosting = MenuHostingView(rootView: chart)
        hosting.applyMeasuredHeight(width: 400, height: hosting.measuredFittingHeight(width: 400))
        let item = NSMenuItem()
        item.view = hosting
        item.isEnabled = true
        let menu = NSMenu()
        menu.addItem(item)

        defer {
            menu.cancelTracking()
            host.close()
            _ = application.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApplication?.activate()
            }
        }
        XCTAssertTrue(application.setActivationPolicy(.regular))
        application.finishLaunching()
        application.activate(ignoringOtherApps: true)
        host.makeKeyAndOrderFront(nil)

        let driver = CostMetricProofDriver(hosting: hosting, menu: menu)
        driver.start()
        defer { driver.stop() }
        let popupPoint = NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY)
        menu.popUp(positioning: nil, at: popupPoint, in: nil)

        if let failure = driver.failure {
            return XCTFail(failure)
        }
        XCTAssertTrue(driver.topEdgeConstraintVerified)
        XCTAssertTrue(driver.verticalConstraintVerified)
        XCTAssertTrue(driver.metricControlClearanceVerified)
        XCTAssertTrue(driver.chartHoverClearanceVerified)
        XCTAssertTrue(driver.chartPointerVerified)
        XCTAssertEqual(driver.pointerSegments, [1, 0])
        XCTAssertEqual(driver.selectedSegments, [1, 0])
        XCTAssertFalse(driver.observedOrigins.isEmpty)
    }
}

@MainActor
private final class CostMetricProofDriver {
    private let hosting: MenuHostingView<CostHistoryChartMenuView>
    private let menu: NSMenu
    private var timer: Timer?
    private var stage = 0
    private var proofStartedAt = Date()
    private var stageStartedAt = Date()
    private var baselineOrigin: CGPoint?
    private(set) var observedOrigins: [CGPoint] = []
    private(set) var pointerSegments: [Int] = []
    private(set) var selectedSegments: [Int] = []
    private(set) var topEdgeConstraintVerified = false
    private(set) var verticalConstraintVerified = false
    private(set) var metricControlClearanceVerified = false
    private(set) var chartHoverClearanceVerified = false
    private(set) var chartPointerVerified = false
    private(set) var failure: String?

    init(hosting: MenuHostingView<CostHistoryChartMenuView>, menu: NSMenu) {
        self.hosting = hosting
        self.menu = menu
    }

    func start() {
        self.proofStartedAt = Date()
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        self.timer?.invalidate()
        self.timer = nil
    }

    private func tick() {
        guard let control = Self.descendant(of: self.hosting, as: NSSegmentedControl.self),
              let chartHoverView = Self.descendant(of: self.hosting, as: MouseLocationReader.TrackingView.self),
              let scrollView = self.hosting.enclosingScrollView
        else {
            if Date().timeIntervalSince(self.proofStartedAt) > 5 {
                self.failure = "Native metric proof could not find the picker, chart hover view, or menu scroll view."
                self.finish()
            }
            return
        }
        let origin = scrollView.contentView.documentVisibleRect.origin
        self.observedOrigins.append(origin)
        switch self.stage {
        case 0:
            guard self.verifyTopEdgeConstraint(
                scrollView,
                control: control,
                chartHoverView: chartHoverView)
            else { return }
            self.baselineOrigin = origin
            Self.movePointer(to: chartHoverView)
            self.advance(to: 1)
        case 1 where Date().timeIntervalSince(self.stageStartedAt) >= 0.25:
            guard self.verifyPointer(in: chartHoverView) else { return }
            self.chartPointerVerified = true
            guard self.requireStable(origin, action: "Hovering the chart") else { return }
            Self.movePointer(toSegment: 1, in: control)
            self.advance(to: 2)
        case 2 where Date().timeIntervalSince(self.stageStartedAt) >= 0.25:
            guard self.verifyPointer(atSegment: 1, in: control) else { return }
            guard self.requireStable(origin, action: "Hovering the cost segment") else { return }
            guard self.activateSegment(1, in: control) else { return }
            self.advance(to: 3)
        case 3 where control.selectedSegment == 1:
            self.selectedSegments.append(1)
            guard self.requireStable(origin, action: "Switching to cost") else { return }
            Self.movePointer(toSegment: 0, in: control)
            self.advance(to: 4)
        case 4 where Date().timeIntervalSince(self.stageStartedAt) >= 0.25:
            guard self.verifyPointer(atSegment: 0, in: control) else { return }
            guard self.requireStable(origin, action: "Hovering the token segment") else { return }
            guard self.activateSegment(0, in: control) else { return }
            self.advance(to: 5)
        case 5 where control.selectedSegment == 0:
            self.selectedSegments.append(0)
            _ = self.requireStable(origin, action: "Switching to tokens")
            self.finish()
        default:
            if Date().timeIntervalSince(self.stageStartedAt) > 5 {
                self.failure = "Native metric proof timed out at stage \(self.stage)."
                self.finish()
            }
        }
    }

    private func verifyTopEdgeConstraint(
        _ scrollView: NSScrollView,
        control: NSSegmentedControl,
        chartHoverView: NSView) -> Bool
    {
        guard let menuWindow = scrollView.window,
              let screen = menuWindow.screen,
              let documentView = scrollView.documentView
        else {
            self.failure = "Native metric proof could not resolve the menu window, display, or document view."
            self.finish()
            return false
        }

        let menuFrame = menuWindow.frame
        let visibleFrame = screen.visibleFrame
        let topEdgeDistance = abs(visibleFrame.maxY - menuFrame.maxY)
        // AppKit keeps a five-point safety inset around a constrained native menu.
        guard topEdgeDistance <= 6 else {
            self.failure = "Native metric proof menu missed the display top edge by \(topEdgeDistance) points."
            self.finish()
            return false
        }
        self.topEdgeConstraintVerified = true

        let documentHeight = documentView.bounds.height
        let viewportHeight = scrollView.contentView.documentVisibleRect.height
        guard documentHeight > viewportHeight + 1 else {
            self.failure = "Native metric proof menu was not vertically constrained "
                + "(document=\(documentHeight), viewport=\(viewportHeight))."
            self.finish()
            return false
        }
        self.verticalConstraintVerified = true

        let controlTopInWindow = control.convert(
            NSPoint(x: control.bounds.midX, y: control.bounds.maxY),
            to: nil)
        let controlTopOnScreen = menuWindow.convertPoint(toScreen: controlTopInWindow).y
        let controlTopClearance = menuFrame.maxY - controlTopOnScreen
        // Two control heights provide a scale-aware guard against the native menu's top scroll affordance.
        let minimumControlTopClearance = control.bounds.height * 2
        guard controlTopClearance >= minimumControlTopClearance else {
            self.failure = "Native metric proof control remained in the menu's top scroll gutter "
                + "(clearance=\(controlTopClearance), minimum=\(minimumControlTopClearance))."
            self.finish()
            return false
        }
        self.metricControlClearanceVerified = true

        let hoverFrameInWindow = chartHoverView.convert(chartHoverView.bounds, to: nil)
        let hoverTopOnScreen = menuWindow.convertPoint(
            toScreen: NSPoint(x: hoverFrameInWindow.midX, y: hoverFrameInWindow.maxY)).y
        let hoverTopClearance = menuFrame.maxY - hoverTopOnScreen
        guard hoverTopClearance >= minimumControlTopClearance else {
            self.failure = "Native metric proof chart hover surface remained in the menu's top scroll gutter "
                + "(clearance=\(hoverTopClearance), minimum=\(minimumControlTopClearance))."
            self.finish()
            return false
        }
        self.chartHoverClearanceVerified = true
        return true
    }

    private func advance(to stage: Int) {
        self.stage = stage
        self.stageStartedAt = Date()
    }

    private func requireStable(_ origin: CGPoint, action: String) -> Bool {
        guard Self.matches(origin, self.baselineOrigin) else {
            let baseline = String(describing: self.baselineOrigin)
            self.failure = "\(action) scrolled the native menu from \(baseline) to \(origin)."
            self.finish()
            return false
        }
        return true
    }

    private func finish() {
        self.stop()
        self.menu.cancelTracking()
    }

    private static func matches(_ origin: CGPoint, _ baseline: CGPoint?) -> Bool {
        guard let baseline else { return false }
        return abs(origin.x - baseline.x) <= 1 && abs(origin.y - baseline.y) <= 1
    }

    private static func descendant<T: NSView>(of view: NSView, as _: T.Type) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = self.descendant(of: subview, as: T.self) { return match }
        }
        return nil
    }

    private static func movePointer(toSegment segment: Int, in control: NSSegmentedControl) {
        let point = self.eventPoint(forSegment: segment, in: control)
        self.postPointerMove(to: point)
    }

    private static func movePointer(to view: NSView) {
        let local = NSPoint(x: view.bounds.midX, y: view.bounds.minY + 1)
        self.postPointerMove(to: self.eventPoint(local: local, in: view))
    }

    private static func postPointerMove(to point: CGPoint) {
        CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func activateSegment(_ segment: Int, in control: NSSegmentedControl) -> Bool {
        control.selectedSegment = segment
        guard let action = control.action,
              NSApplication.shared.sendAction(action, to: control.target, from: control)
        else {
            self.failure = "Native metric proof could not dispatch the segmented control action."
            self.finish()
            return false
        }
        return true
    }

    private func verifyPointer(in view: NSView) -> Bool {
        guard let window = view.window else {
            self.failure = "Native metric proof could not resolve the chart hover window."
            self.finish()
            return false
        }
        let viewPoint = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard view.bounds.contains(viewPoint) else {
            self.failure = "Native metric proof pointer did not reach the chart hover surface."
            self.finish()
            return false
        }
        return true
    }

    private func verifyPointer(atSegment expectedSegment: Int, in control: NSSegmentedControl) -> Bool {
        guard let window = control.window, control.segmentCount > 0 else {
            self.failure = "Native metric proof could not resolve the segmented control window."
            self.finish()
            return false
        }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let controlPoint = control.convert(windowPoint, from: nil)
        guard control.bounds.contains(controlPoint) else {
            self.failure = "Native metric proof pointer did not reach the segmented control."
            self.finish()
            return false
        }
        let segmentWidth = control.bounds.width / CGFloat(control.segmentCount)
        let reachedSegment = min(Int(controlPoint.x / segmentWidth), control.segmentCount - 1)
        guard reachedSegment == expectedSegment else {
            self.failure = "Native metric proof pointer reached segment \(reachedSegment), "
                + "expected \(expectedSegment)."
            self.finish()
            return false
        }
        self.pointerSegments.append(reachedSegment)
        return true
    }

    private static func eventPoint(forSegment segment: Int, in control: NSSegmentedControl) -> CGPoint {
        let segmentWidth = control.bounds.width / CGFloat(max(control.segmentCount, 1))
        let local = NSPoint(x: segmentWidth * (CGFloat(segment) + 0.5), y: control.bounds.midY)
        return self.eventPoint(local: local, in: control)
    }

    private static func eventPoint(local: NSPoint, in view: NSView) -> CGPoint {
        let windowPoint = view.convert(local, to: nil)
        let cocoaPoint = view.window?.convertPoint(toScreen: windowPoint) ?? windowPoint
        let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGPoint(x: cocoaPoint.x, y: mainDisplayHeight - cocoaPoint.y)
    }
}
