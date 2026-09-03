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

        let fixture = makeCostMetricProofFixture()
        let metricChanges = fixture.metricChanges
        let hosting = fixture.hosting
        let item = NSMenuItem()
        item.view = hosting
        item.isEnabled = true
        let menu = NSMenu()
        menu.autoenablesItems = false
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

        let driver = CostMetricProofDriver(hosting: hosting, menu: menu, verifyWheel: true)
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
        XCTAssertEqual(metricChanges.values, [.cost, .tokens])
        XCTAssertTrue(driver.wheelScrollVerified)
        XCTAssertFalse(driver.observedOrigins.isEmpty)
    }

    func test_costHistoryChartKeepsViewportWhenOpenedFromNestedNativeMenu() throws {
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
        host.title = "CodexBar Nested Cost Metric Proof"
        host.isReleasedWhenClosed = false
        guard let screen = host.screen ?? NSScreen.main else {
            return XCTFail("Native metric proof requires an attached display.")
        }

        let fixture = makeCostMetricProofFixture()
        let metricChanges = fixture.metricChanges
        let hosting = fixture.hosting
        let chartItem = NSMenuItem()
        chartItem.view = hosting
        chartItem.isEnabled = true
        let chartMenu = NSMenu()
        chartMenu.autoenablesItems = false
        chartMenu.addItem(chartItem)
        let parentItem = NSMenuItem(title: "Cost history", action: nil, keyEquivalent: "")
        parentItem.isEnabled = true
        parentItem.submenu = chartMenu
        let rootMenu = StatusItemMenu()
        rootMenu.autoenablesItems = false
        rootMenu.addItem(parentItem)

        defer {
            rootMenu.cancelTracking()
            chartMenu.cancelTracking()
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

        let popupPoint = NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY)
        let driver = CostMetricProofDriver(
            hosting: hosting,
            menu: chartMenu,
            rootMenu: rootMenu,
            rootPopupPoint: popupPoint,
            stopAfterChartHover: true)
        driver.start()
        defer { driver.stop() }
        rootMenu.popUp(positioning: nil, at: popupPoint, in: nil)

        XCTAssertTrue(driver.nestedPointerSent)
        XCTAssertTrue(driver.nestedSubmenuObserved)
        if let failure = driver.failure {
            return XCTFail(failure)
        }
        XCTAssertTrue(driver.topEdgeConstraintVerified)
        XCTAssertTrue(driver.verticalConstraintVerified)
        XCTAssertTrue(driver.metricControlClearanceVerified)
        XCTAssertTrue(driver.chartHoverClearanceVerified)
        XCTAssertTrue(driver.chartPointerVerified)
        XCTAssertTrue(metricChanges.values.isEmpty)
        XCTAssertFalse(driver.observedOrigins.isEmpty)
    }
}

@MainActor
private func makeCostMetricProofFixture() -> (
    hosting: MenuHostingView<CostHistoryChartMenuView>,
    metricChanges: MetricChangeRecorder)
{
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
        let sources = (1...3).map { sourceIndex in
            CostUsageProjectSourceBreakdown(
                name: "Fixture source \(sourceIndex)",
                path: "/tmp/codexbar-cost-proof/source-\(index)-\(sourceIndex)",
                totalTokens: sourceIndex * 1000,
                totalCostUSD: Double(sourceIndex),
                daily: [],
                modelBreakdowns: nil)
        }
        projects.append(CostUsageProjectBreakdown(
            name: "Fixture project \(index)",
            path: "/tmp/codexbar-cost-proof/project-\(index)",
            totalTokens: index * 10000,
            totalCostUSD: Double(index),
            daily: [],
            modelBreakdowns: nil,
            sources: sources))

        sessions.append(CostUsageSessionBreakdown(
            sessionID: "fixture-session-\(index)",
            lastActivity: Date(timeIntervalSince1970: TimeInterval(index)),
            inputTokens: index * 1000,
            cachedInputTokens: index * 500,
            outputTokens: index * 100,
            totalTokens: index * 1100,
            requestCount: index,
            costUSD: Double(index),
            modelBreakdowns: []))
    }
    let metricChanges = MetricChangeRecorder()
    let chart = CostHistoryChartMenuView(
        provider: .codex,
        daily: daily,
        totalCostUSD: daily.reduce(0) { $0 + ($1.costUSD ?? 0) },
        projects: projects,
        sessions: sessions,
        hidePersonalInfo: false,
        width: 400,
        onMetricChanged: { metricChanges.values.append($0) })
    let hosting = MenuHostingView(rootView: chart)
    hosting.applyMeasuredHeight(width: 400, height: hosting.measuredFittingHeight(width: 400))
    return (hosting, metricChanges)
}

@MainActor
private final class MetricChangeRecorder {
    var values: [CostHistoryChartMenuView.ChartMetric] = []
}

@MainActor
private final class CostMetricProofDriver {
    private let hosting: MenuHostingView<CostHistoryChartMenuView>
    private let menu: NSMenu
    private let rootMenu: NSMenu?
    private let rootPopupPoint: NSPoint?
    private let stopAfterChartHover: Bool
    private let verifyWheel: Bool
    private(set) var nestedPointerSent = false
    private var timer: Timer?
    private var stage = 0
    private var proofStartedAt = Date()
    private var stageStartedAt = Date()
    private var baselineOrigin: CGPoint?
    private var wheelBaselineOrigin: CGPoint?
    private var wheelArmedAt: Date?
    private var wheelPointerMovedAt: Date?
    private var wheelPointerMoved = false
    private var wheelPosted = false
    private(set) var observedOrigins: [CGPoint] = []
    private(set) var pointerSegments: [Int] = []
    private(set) var selectedSegments: [Int] = []
    private(set) var topEdgeConstraintVerified = false
    private(set) var verticalConstraintVerified = false
    private(set) var metricControlClearanceVerified = false
    private(set) var chartHoverClearanceVerified = false
    private(set) var chartPointerVerified = false
    private(set) var wheelScrollVerified = false
    private(set) var nestedSubmenuObserved = false
    private(set) var failure: String?

    init(
        hosting: MenuHostingView<CostHistoryChartMenuView>,
        menu: NSMenu,
        rootMenu: NSMenu? = nil,
        rootPopupPoint: NSPoint? = nil,
        stopAfterChartHover: Bool = false,
        verifyWheel: Bool = false)
    {
        self.hosting = hosting
        self.menu = menu
        self.rootMenu = rootMenu
        self.rootPopupPoint = rootPopupPoint
        self.stopAfterChartHover = stopAfterChartHover
        self.verifyWheel = verifyWheel
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

    private struct ProofContext {
        let control: NSSegmentedControl
        let chartHoverView: MouseLocationReader.TrackingView
        let scrollView: NSScrollView
        let origin: NSPoint
    }

    private func tick() {
        self.sendPointerToNestedParentIfNeeded()
        guard let context = self.proofContext() else {
            self.handleMissingProofContext()
            return
        }
        if self.rootMenu != nil {
            self.nestedSubmenuObserved = true
        }
        self.observedOrigins.append(context.origin)
        switch self.stage {
        case 0:
            self.handleInitialStage(context)
        case 1:
            self.handleChartHoverStage(context)
        case 2:
            self.handleCostHoverStage(context)
        case 3:
            self.handleCostSelectedStage(context)
        case 4:
            self.handleTokenHoverStage(context)
        case 5:
            self.handleTokenSelectedStage(context)
        case 6:
            self.handleWheelStage(context)
        default:
            self.handleStageTimeout()
        }
    }

    private func sendPointerToNestedParentIfNeeded() {
        guard let rootPopupPoint = self.rootPopupPoint, self.hosting.window == nil else { return }
        self.nestedPointerSent = true
        Self.postPointerMove(toCocoaScreen: NSPoint(x: rootPopupPoint.x, y: rootPopupPoint.y - 12))
    }

    private func proofContext() -> ProofContext? {
        guard let control = Self.descendant(of: self.hosting, as: NSSegmentedControl.self),
              let chartHoverView = Self.descendant(of: self.hosting, as: MouseLocationReader.TrackingView.self),
              let scrollView = self.hosting.enclosingScrollView
        else {
            return nil
        }
        return ProofContext(
            control: control,
            chartHoverView: chartHoverView,
            scrollView: scrollView,
            origin: scrollView.contentView.documentVisibleRect.origin)
    }

    private func handleMissingProofContext() {
        guard Date().timeIntervalSince(self.proofStartedAt) > 5 else { return }
        self.failure = "Native metric proof could not find the picker, chart hover view, or menu scroll view."
        self.finish()
    }

    private func handleInitialStage(_ context: ProofContext) {
        guard self.verifyTopEdgeConstraint(
            context.scrollView,
            control: context.control,
            chartHoverView: context.chartHoverView)
        else { return }
        self.baselineOrigin = context.origin
        Self.movePointer(to: context.chartHoverView)
        self.advance(to: 1)
    }

    private func handleChartHoverStage(_ context: ProofContext) {
        guard Date().timeIntervalSince(self.stageStartedAt) >= 0.25 else { return }
        guard self.verifyPointer(in: context.chartHoverView) else { return }
        self.chartPointerVerified = true
        guard self.requireStable(context.origin, action: "Hovering the chart") else { return }
        if self.stopAfterChartHover {
            self.finish()
            return
        }
        Self.movePointer(toSegment: 1, in: context.control)
        self.advance(to: 2)
    }

    private func handleCostHoverStage(_ context: ProofContext) {
        guard Date().timeIntervalSince(self.stageStartedAt) >= 0.25 else { return }
        guard self.verifyPointer(atSegment: 1, in: context.control) else { return }
        guard self.requireStable(context.origin, action: "Hovering the cost segment") else { return }
        guard self.activateSegment(1, in: context.control) else { return }
        self.advance(to: 3)
    }

    private func handleCostSelectedStage(_ context: ProofContext) {
        guard context.control.selectedSegment == 1 else { return }
        self.selectedSegments.append(1)
        guard self.requireStable(context.origin, action: "Switching to cost") else { return }
        Self.movePointer(toSegment: 0, in: context.control)
        self.advance(to: 4)
    }

    private func handleTokenHoverStage(_ context: ProofContext) {
        guard Date().timeIntervalSince(self.stageStartedAt) >= 0.25 else { return }
        guard self.verifyPointer(atSegment: 0, in: context.control) else { return }
        guard self.requireStable(context.origin, action: "Hovering the token segment") else { return }
        guard self.activateSegment(0, in: context.control) else { return }
        self.advance(to: 5)
    }

    private func handleTokenSelectedStage(_ context: ProofContext) {
        guard context.control.selectedSegment == 0 else { return }
        self.selectedSegments.append(0)
        guard self.requireStable(context.origin, action: "Switching to tokens") else { return }
        if self.verifyWheel {
            self.advance(to: 6)
        } else {
            self.finish()
        }
    }

    private func handleWheelStage(_ context: ProofContext) {
        guard Date().timeIntervalSince(self.stageStartedAt) >= 0.5 else { return }
        if !self.wheelPosted {
            if self.wheelBaselineOrigin == nil {
                // Start away from the top so the real wheel event has room to move the viewport.
                context.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
                context.scrollView.reflectScrolledClipView(context.scrollView.contentView)
                self.wheelBaselineOrigin = context.scrollView.contentView.documentVisibleRect.origin
                self.wheelArmedAt = Date()
                return
            }
            guard Self.matches(context.origin, self.wheelBaselineOrigin) else {
                self.failure = "Native metric proof menu moved before the wheel event was posted."
                self.finish()
                return
            }
            guard let wheelArmedAt = self.wheelArmedAt,
                  Date().timeIntervalSince(wheelArmedAt) >= 0.5
            else { return }
            if !self.wheelPointerMoved {
                self.wheelPointerMoved = true
                self.wheelPointerMovedAt = Date()
                Self.movePointer(to: context.chartHoverView)
                return
            }
            guard Self.matches(context.origin, self.wheelBaselineOrigin) else {
                self.failure = "Native metric proof menu moved while placing the pointer for the wheel event."
                self.finish()
                return
            }
            guard let wheelPointerMovedAt = self.wheelPointerMovedAt,
                  Date().timeIntervalSince(wheelPointerMovedAt) >= 0.1
            else { return }
            self.wheelPosted = true
            Self.movePointer(to: context.chartHoverView)
            Self.postScrollWheel(delta: -8)
        } else if !Self.matches(context.origin, self.wheelBaselineOrigin) {
            self.wheelScrollVerified = true
            self.finish()
        } else if Date().timeIntervalSince(self.stageStartedAt) > 5 {
            self.failure = "Native metric proof wheel event did not move the menu viewport."
            self.finish()
        }
    }

    private func handleStageTimeout() {
        guard Date().timeIntervalSince(self.stageStartedAt) > 5 else { return }
        self.failure = "Native metric proof timed out at stage \(self.stage)."
        self.finish()
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
        let topEdgeTolerance: CGFloat = self.rootMenu == nil ? 6 : 30
        guard topEdgeDistance <= topEdgeTolerance else {
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
        self.rootMenu?.cancelTracking()
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

    private static func postScrollWheel(delta: Int32) {
        CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: delta,
            wheel2: 0,
            wheel3: 0)?.post(tap: .cghidEventTap)
    }

    private static func postPointerMove(toCocoaScreen point: NSPoint) {
        let displayHeight = CGDisplayBounds(CGMainDisplayID()).height
        self.postPointerMove(to: CGPoint(x: point.x, y: displayHeight - point.y))
    }

    private func activateSegment(_ segment: Int, in control: NSSegmentedControl) -> Bool {
        let point = Self.eventPoint(forSegment: segment, in: control)
        guard let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left),
            let mouseUp = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left)
        else {
            self.failure = "Native metric proof could not create the segmented control click events."
            self.finish()
            return false
        }
        mouseDown.setIntegerValueField(.mouseEventClickState, value: 1)
        mouseUp.setIntegerValueField(.mouseEventClickState, value: 1)
        mouseDown.post(tap: .cghidEventTap)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        mouseUp.post(tap: .cghidEventTap)
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
