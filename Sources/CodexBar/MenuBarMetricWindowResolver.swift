import CodexBarCore
import Foundation

enum MenuBarMetricWindowResolver {
    private enum Lane {
        case primary
        case secondary
        case tertiary
    }

    static func rateWindow(
        preference: MenuBarMetricPreference,
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        supportsAverage: Bool,
        now: Date = Date())
        -> RateWindow?
    {
        guard let snapshot else { return nil }
        switch preference {
        case .monthlyPlan:
            return snapshot.extraRateWindows?.first { $0.id == "mistral-monthly-plan" }?.window
        case .extraUsage:
            return Self.extraUsageWindow(snapshot: snapshot)
        case .tertiary:
            return Self.requestedWindow(
                provider: provider,
                snapshot: snapshot,
                lanes: Self.tertiaryOrder(for: provider))
        case .primary:
            return Self.requestedWindow(
                provider: provider,
                snapshot: snapshot,
                lanes: Self.primaryOrder(for: provider))
        case .secondary:
            return Self.requestedWindow(
                provider: provider,
                snapshot: snapshot,
                lanes: Self.secondaryOrder(for: provider))
        case .primaryAndSecondary:
            // Claude accounts that only expose an enterprise/extra-usage spend limit have no real
            // session/weekly lanes; surface the spend limit (as `.automatic` does) instead of an empty
            // or 0% placeholder lane.
            if provider == .claude, let spendLimit = Self.claudeSpendLimitWindow(snapshot: snapshot) {
                return spendLimit
            }
            return Self.mostConstrainedWindow(
                primary: snapshot.primary,
                secondary: snapshot.secondary,
                tertiary: nil)
        case .average:
            return Self.averageWindow(provider: provider, snapshot: snapshot, supportsAverage: supportsAverage)
        case .automatic:
            return Self.automaticWindow(provider: provider, snapshot: snapshot)
        }
    }

    private static func tertiaryOrder(for provider: UsageProvider) -> [Lane] {
        if provider == .zai {
            return [.tertiary, .primary, .secondary]
        }
        if provider == .perplexity || provider == .cursor || provider == .antigravity {
            return [.tertiary, .secondary, .primary]
        }
        return [.primary, .secondary]
    }

    private static func primaryOrder(for provider: UsageProvider) -> [Lane] {
        if provider == .zai {
            return [.primary, .tertiary, .secondary]
        }
        if provider == .perplexity || provider == .antigravity {
            return [.primary, .secondary, .tertiary]
        }
        return [.primary, .secondary]
    }

    private static func secondaryOrder(for provider: UsageProvider) -> [Lane] {
        if provider == .zai || provider == .antigravity {
            return [.secondary, .primary, .tertiary]
        }
        if provider == .perplexity {
            return [.secondary, .tertiary, .primary]
        }
        return [.secondary, .primary]
    }

    private static func averageWindow(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        supportsAverage: Bool)
        -> RateWindow?
    {
        guard supportsAverage,
              let primary = snapshot.primary,
              let secondary = snapshot.secondary
        else {
            if provider == .antigravity {
                return self.window(in: snapshot, following: [.primary, .secondary, .tertiary])
            }
            return snapshot.primary ?? snapshot.secondary
        }

        let usedPercent = (primary.usedPercent + secondary.usedPercent) / 2
        return RateWindow(usedPercent: usedPercent, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
    }

    private static func automaticWindow(provider: UsageProvider, snapshot: UsageSnapshot) -> RateWindow?
    {
        if provider == .antigravity {
            if let window = antigravityQuotaRankingWindow(snapshot: snapshot) {
                return window
            }
            return self.mostConstrainedWindow(
                primary: snapshot.primary,
                secondary: snapshot.secondary,
                tertiary: snapshot.tertiary)
                ?? self.mostConstrainedAntigravityLegacyExtraWindow(snapshot: snapshot)
        }
        if provider == .perplexity {
            return snapshot.automaticPerplexityWindow()
        }
        if provider == .zai {
            return self.mostConstrainedWindow(
                primary: snapshot.primary,
                secondary: snapshot.tertiary,
                tertiary: nil) ?? snapshot.secondary
        }
        if provider == .factory || provider == .kimi {
            return snapshot.secondary ?? snapshot.primary
        }
        if provider == .litellm {
            return snapshot.secondary ?? snapshot.primary
        }
        if provider == .copilot,
           let primary = snapshot.primary,
           let secondary = snapshot.secondary
        {
            return primary.usedPercent >= secondary.usedPercent ? primary : secondary
        }
        if provider == .cursor {
            return Self.mostConstrainedCursorWindow(
                total: snapshot.primary,
                auto: snapshot.secondary,
                api: snapshot.tertiary)
        }
        if provider == .minimax {
            return Self.mostConstrainedWindow(
                primary: snapshot.primary,
                secondary: snapshot.secondary,
                tertiary: snapshot.tertiary)
        }
        if provider == .claude, let spendLimit = Self.claudeSpendLimitWindow(snapshot: snapshot) {
            return spendLimit
        }
        return snapshot.primary ?? snapshot.secondary
    }

    static let antigravityQuotaSummaryWindowIDPrefix = "antigravity-quota-summary-"
    static let antigravityCompactFallbackWindowIDPrefix = "antigravity-compact-fallback-"

    /// Automatic menu-bar presentation and highest-usage ranking use the same binding quota
    /// lane, so an exhausted quota cannot be hidden by a less-used lane that resets sooner.
    static func antigravityQuotaRankingWindow(snapshot: UsageSnapshot) -> RateWindow? {
        let windows = Self.antigravityQuotaSummaryWindows(snapshot: snapshot)
        return windows.max { lhs, rhs in
            if lhs.usedPercent != rhs.usedPercent {
                return lhs.usedPercent < rhs.usedPercent
            }
            return (lhs.resetsAt ?? .distantFuture) > (rhs.resetsAt ?? .distantFuture)
        }
    }

    /// Returns whether every reported model family has a binding exhausted bucket.
    /// A family is blocked when either its five-hour or weekly bucket is exhausted.
    static func antigravityQuotaSummaryFamiliesAreAllBlocked(snapshot: UsageSnapshot) -> Bool? {
        let recognized = Self.antigravityQuotaSummaryWindowsWithIDs(snapshot: snapshot).compactMap { namedWindow -> (
            family: String,
            window: RateWindow)? in
            guard let family = Self.antigravityQuotaFamilyID(for: namedWindow) else { return nil }
            return (family, namedWindow.window)
        }
        guard !recognized.isEmpty else { return nil }
        let families = Dictionary(grouping: recognized) { $0.family }
        let grouped = families.mapValues { values in
            values.map(\.window)
        }
        return grouped.values.allSatisfy { familyWindows in
            familyWindows.contains { $0.usedPercent >= 100 }
        }
    }

    private static func antigravityQuotaSummaryWindows(snapshot: UsageSnapshot) -> [RateWindow] {
        self.antigravityQuotaSummaryWindowsWithIDs(snapshot: snapshot).map(\.window)
    }

    private static func antigravityQuotaSummaryWindowsWithIDs(snapshot: UsageSnapshot) -> [NamedRateWindow] {
        snapshot.extraRateWindows?.filter {
            $0.usageKnown && $0.id.hasPrefix(Self.antigravityQuotaSummaryWindowIDPrefix)
                && ($0.window.windowMinutes == 300 || $0.window.windowMinutes == 10080)
        } ?? []
    }

    private static func antigravityQuotaFamilyID(for namedWindow: NamedRateWindow) -> String? {
        let id = namedWindow.id
        guard id.hasPrefix(self.antigravityQuotaSummaryWindowIDPrefix) else { return nil }
        let suffix = id.dropFirst(Self.antigravityQuotaSummaryWindowIDPrefix.count)
        if namedWindow.window.windowMinutes == 300 {
            for cadenceSuffix in ["-5h", "-5-hour", "-five-hour", "-session"] where suffix.hasSuffix(cadenceSuffix) {
                return String(suffix.dropLast(cadenceSuffix.count))
            }
        }
        if namedWindow.window.windowMinutes == 10080, suffix.hasSuffix("-weekly") {
            return String(suffix.dropLast(7))
        }
        return nil
    }

    private static func mostConstrainedAntigravityLegacyExtraWindow(snapshot: UsageSnapshot) -> RateWindow? {
        let windows = snapshot.extraRateWindows?
            .filter {
                $0.usageKnown && $0.id.hasPrefix(Self.antigravityCompactFallbackWindowIDPrefix)
            }
            .map(\.window) ?? []
        return windows.max(by: { $0.usedPercent < $1.usedPercent })
    }

    private static func requestedWindow(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        lanes: [Lane]) -> RateWindow?
    {
        self.window(in: snapshot, following: lanes)
            ?? (provider == .antigravity
                ? self.mostConstrainedAntigravityLegacyExtraWindow(snapshot: snapshot)
                : nil)
    }

    private static func window(in snapshot: UsageSnapshot, following lanes: [Lane]) -> RateWindow? {
        for lane in lanes {
            if let window = self.window(in: snapshot, lane: lane) {
                return window
            }
        }
        return nil
    }

    private static func window(in snapshot: UsageSnapshot, lane: Lane) -> RateWindow? {
        switch lane {
        case .primary:
            snapshot.primary
        case .secondary:
            snapshot.secondary
        case .tertiary:
            snapshot.tertiary
        }
    }

    private static func mostConstrainedWindow(
        primary: RateWindow?,
        secondary: RateWindow?,
        tertiary: RateWindow?)
        -> RateWindow?
    {
        let windows = [primary, secondary, tertiary].compactMap(\.self)
        guard !windows.isEmpty else { return nil }
        return windows.max(by: { $0.usedPercent < $1.usedPercent })
    }

    private static func mostConstrainedCursorWindow(
        total: RateWindow?,
        auto: RateWindow?,
        api: RateWindow?)
        -> RateWindow?
    {
        if let total, total.usedPercent >= 100 {
            return total
        }

        let subquotaWindows = [auto, api].compactMap(\.self)
        let usableSubquotaWindows = subquotaWindows.filter { $0.usedPercent < 100 }
        if !subquotaWindows.isEmpty, usableSubquotaWindows.isEmpty {
            return subquotaWindows.max(by: { $0.usedPercent < $1.usedPercent })
        }

        return ([total].compactMap(\.self) + usableSubquotaWindows)
            .max(by: { $0.usedPercent < $1.usedPercent })
    }

    /// The Claude spend-limit window when the account only exposes an enterprise/extra-usage spend limit
    /// and has no real session/weekly quota lanes (`primary` nil, a `.spendLimit` window, or an explicitly
    /// marked placeholder). Lets the automatic and combined metrics surface the spend limit instead of an empty
    /// or 0% placeholder lane. Returns nil for accounts that expose genuine quota lanes.
    static func claudeSpendLimitWindow(snapshot: UsageSnapshot) -> RateWindow? {
        guard self.shouldUseClaudeSpendLimit(providerCost: snapshot.providerCost, snapshot: snapshot) else {
            return nil
        }
        return self.extraUsageWindow(snapshot: snapshot)
    }

    private static func shouldUseClaudeSpendLimit(
        providerCost: ProviderCostSnapshot?,
        snapshot: UsageSnapshot)
        -> Bool
    {
        guard providerCost?.limit ?? 0 > 0,
              snapshot.secondary == nil,
              snapshot.tertiary == nil
        else { return false }
        guard let primary = snapshot.primary else { return true }
        return primary.isSyntheticPlaceholder
    }

    private static func extraUsageWindow(snapshot: UsageSnapshot?) -> RateWindow? {
        guard let cost = snapshot?.providerCost, cost.limit > 0 else { return nil }
        let usedPercent = max(0, min(100, (cost.used / cost.limit) * 100))
        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: cost.resetsAt,
            resetDescription: nil)
    }
}
