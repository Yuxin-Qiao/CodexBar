import CodexBarCore
import Foundation

extension StatusItemController {
    func storeIconObservationSignature() -> String {
        let showBrandPercent = self.settings.menuBarShowsBrandIconWithPercent
        let mergeIcons = self.shouldMergeIcons
        let visibleProviders = self.store.enabledProvidersForDisplay().map(\.rawValue).sorted().joined(separator: ",")
        let providerSignatures: String
        let primaryProvider: UsageProvider?
        if mergeIcons {
            let primary = self.primaryProviderForUnifiedIcon()
            primaryProvider = primary
            providerSignatures = self.providerStoreIconObservationSignature(
                for: primary,
                showBrandPercent: showBrandPercent)
        } else {
            primaryProvider = nil
            providerSignatures = UsageProvider.allCases
                .filter { self.isVisible($0) }
                .map { self.providerStoreIconObservationSignature(for: $0, showBrandPercent: showBrandPercent) }
                .joined(separator: "||")
        }
        return [
            "merge=\(mergeIcons ? "1" : "0")",
            "visible=\(visibleProviders)",
            "primary=\(primaryProvider?.rawValue ?? "nil")",
            "iconStyle=\(self.store.iconStyle.rawValue)",
            "showUsed=\(self.settings.usageBarsShowUsed ? "1" : "0")",
            "brandPercent=\(showBrandPercent ? "1" : "0")",
            "hideCritters=\(self.settings.menuBarHidesCritters ? "1" : "0")",
            "needsAnimation=\(self.needsMenuBarIconAnimation() ? "1" : "0")",
            providerSignatures,
        ].joined(separator: "|")
    }

    private func providerStoreIconObservationSignature(for provider: UsageProvider, showBrandPercent: Bool) -> String {
        let snapshot = self.store.snapshot(for: provider)
        let style = self.store.style(for: provider)
        let resolved = self.resolvedMenuBarIconPercents(
            provider: provider,
            snapshot: snapshot,
            style: style,
            showUsed: self.settings.usageBarsShowUsed)
        let creditsRemaining = self.menuBarCreditsRemainingForIcon(provider: provider, snapshot: snapshot)
        let displayText = showBrandPercent ? self.menuBarDisplayText(for: provider, snapshot: snapshot) : nil
        let layoutCostSignature = showBrandPercent
            ? self.storedMenuBarLayoutCostSignature(for: provider)
            : nil
        let layoutAccountSignature = showBrandPercent
            ? self.storedMenuBarLayoutAccountSignature(for: provider, snapshot: snapshot)
            : nil

        return [
            provider.rawValue,
            "style=\(style.rawValue)",
            "primary=\(Self.iconSignatureValue(resolved?.primary))",
            "weekly=\(Self.iconSignatureValue(resolved?.secondary))",
            "credits=\(Self.iconSignatureValue(creditsRemaining))",
            "stale=\(self.store.isStale(provider: provider) ? "1" : "0")",
            "status=\(self.store.statusIndicator(for: provider).rawValue)",
            "anim=\(self.shouldAnimate(provider: provider) ? "1" : "0")",
            "refreshing=\(self.store.refreshingProviders.contains(provider) ? "1" : "0")",
            "text=\(displayText ?? "nil")",
            "layoutCost=\(layoutCostSignature ?? "nil")",
            "layoutAccount=\(layoutAccountSignature ?? "nil")",
            "accountSnapshots=\(self.accountSnapshotSignature(for: provider))",
        ].joined(separator: "|")
    }

    private func accountSnapshotSignature(for provider: UsageProvider) -> String {
        let accountSnapshots = self.store.accountSnapshots[provider] ?? []
        let accountPart = accountSnapshots.map { snap in
            let label = snap.account.label
            let usage = Self.usageSnapshotSignature(snap.snapshot)
            return "\(snap.account.id.uuidString):\(label):\(usage):\(snap.error ?? "nil"):\(snap.sourceLabel ?? "nil")"
        }.joined(separator: ",")

        let codexPart: String = if provider == .codex {
            self.store.codexAccountSnapshots.map { snap in
                let email = snap.account.email
                let active = snap.account.isActive ? "1" : "0"
                let usage = Self.usageSnapshotSignature(snap.snapshot)
                return "\(snap.id):\(email):\(active):\(usage):\(snap.error ?? "nil"):\(snap.sourceLabel ?? "nil")"
            }.joined(separator: ",")
        } else {
            ""
        }

        return "\(accountPart)|\(codexPart)"
    }

    private static func usageSnapshotSignature(_ snapshot: UsageSnapshot?) -> String {
        guard let snapshot else { return "nil" }
        return [
            Self.rateWindowSignature(snapshot.primary),
            Self.rateWindowSignature(snapshot.secondary),
            Self.rateWindowSignature(snapshot.tertiary),
        ].joined(separator: ";")
    }

    private static func rateWindowSignature(_ window: RateWindow?) -> String {
        guard let window else { return "nil" }
        return "\(window.usedPercent)/\(window.windowMinutes ?? -1)/\(window.resetsAt?.timeIntervalSince1970 ?? -1)"
    }

    private func storedMenuBarLayoutAccountSignature(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?)
        -> String?
    {
        let resolution = self.settings.menuBarLayoutResolution(for: provider)
        guard !resolution.usesLegacyRendering,
              resolution.layout.lines.joined().contains(.accountLabel),
              let accountLabel = self.menuBarLayoutAccountLabel(provider: provider, snapshot: snapshot)
        else { return nil }

        var hasher = Hasher()
        hasher.combine(accountLabel)
        return String(hasher.finalize())
    }

    private func storedMenuBarLayoutCostSignature(for provider: UsageProvider) -> String? {
        let resolution = self.settings.menuBarLayoutResolution(for: provider)
        guard !resolution.usesLegacyRendering else { return nil }

        let tokens = resolution.layout.lines.joined()
        let showsToday = tokens.contains(.costToday)
        let showsLast30Days = tokens.contains(.cost30d)
        guard showsToday || showsLast30Days else { return nil }

        let costs = self.menuBarLayoutCostStrings(provider: provider)
        return [
            "today=\(showsToday ? costs.today ?? "nil" : "unused")",
            "last30Days=\(showsLast30Days ? costs.last30Days ?? "nil" : "unused")",
        ].joined(separator: ",")
    }
}
