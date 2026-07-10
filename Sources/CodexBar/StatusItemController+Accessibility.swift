import AppKit
import CodexBarCore

extension StatusItemController {
    private nonisolated static let statusItemAccessibilityTitle = "CodexBar"
    private nonisolated static let debugStatusItemAccessibilityTitle = "CodexBar Debug"

    nonisolated static func isDebugApp(bundleIdentifier: String?) -> Bool {
        bundleIdentifier?.contains(".debug") == true
    }

    nonisolated static func statusItemAccessibilityTitle(isDebugApp: Bool) -> String {
        isDebugApp ? self.debugStatusItemAccessibilityTitle : self.statusItemAccessibilityTitle
    }
}
