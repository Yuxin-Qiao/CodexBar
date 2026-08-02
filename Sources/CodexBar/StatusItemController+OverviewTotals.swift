import AppKit
import CodexBarCore
import SwiftUI

extension StatusItemController {
    func makeOverviewTotalsModel(enabledProviders: [UsageProvider]) -> OverviewTotalsModel? {
        guard self.settings.costUsageEnabled else { return nil }
        let inputs = enabledProviders.compactMap { provider -> OverviewTotalsModel.ProviderInput? in
            guard let publication = self.store.tokenSnapshotPublicationForCurrentProviderConfig(for: provider),
                  let snapshot = publication.snapshot
            else {
                return nil
            }
            let displayName = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
            return OverviewTotalsModel.ProviderInput(
                provider: provider,
                displayName: displayName,
                snapshot: snapshot)
        }
        return OverviewTotalsModel.build(
            inputs: inputs,
            preferredCurrencyCode: self.settings.preferredCurrencyCode)
    }

    func makeOverviewUnifiedModel(
        enabledProviders: [UsageProvider]) -> OverviewUnifiedModel?
    {
        let quotaRows = enabledProviders.compactMap { provider -> OverviewQuotaRow? in
            guard let model = self.menuCardModel(for: provider) else { return nil }
            let displayName = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
            let primary = model.metrics.first(where: { $0.id == "primary" }) ?? model.metrics.first
            guard !model.isOverviewErrorOnly, let primary else {
                // Error-only providers still get a chip so every enabled provider appears once.
                guard model.subtitleStyle == .error, !model.subtitleText.isEmpty else { return nil }
                return OverviewQuotaRow(
                    provider: provider,
                    displayName: displayName,
                    remainingPercent: nil,
                    usedPercent: nil,
                    percentLabel: "",
                    hasError: true,
                    errorText: model.subtitleText,
                    resetText: nil,
                    progressColor: model.progressColor)
            }
            let usedPercent = primary.percentStyle == .used
                ? primary.percent
                : 100 - primary.percent
            let hasError = model.subtitleStyle == .error
            return OverviewQuotaRow(
                provider: provider,
                displayName: displayName,
                remainingPercent: primary.percent,
                usedPercent: min(100, max(0, usedPercent)),
                percentLabel: primary.percentLabel,
                hasError: hasError,
                errorText: hasError && !model.subtitleText.isEmpty ? model.subtitleText : nil,
                resetText: primary.resetText,
                progressColor: model.progressColor)
        }
        guard !quotaRows.isEmpty else { return nil }

        return OverviewUnifiedModel(
            totals: self.makeOverviewTotalsModel(enabledProviders: enabledProviders),
            quotaRows: quotaRows,
            resetLines: Self.makeOverviewResetLines(quotaRows: quotaRows))
    }

    static func makeOverviewResetLines(quotaRows: [OverviewQuotaRow]) -> [String] {
        let lines = quotaRows.compactMap { row -> String? in
            guard !row.hasError, let reset = row.resetText, !reset.isEmpty else { return nil }
            return "\(row.displayName) · \(reset)"
        }
        return Array(lines.prefix(2))
    }

    func addOverviewUnifiedCard(
        _ model: OverviewUnifiedModel,
        to menu: NSMenu,
        menuWidth: CGFloat)
    {
        let submenu = self.makeOverviewUnifiedSubmenu(model: model)
        let item = self.makeMenuCardItem(
            OverviewUnifiedCardView(model: model, width: menuWidth),
            id: Self.overviewUnifiedRowIdentifier,
            width: menuWidth,
            heightCacheScope: "overviewUnified",
            heightCacheFingerprint: model.heightFingerprint,
            submenu: submenu,
            containsInteractiveControls: false,
            usesGPUSelection: true,
            onClick: { [weak self] in
                self?.openUsageSpendPane()
            })
        menu.addItem(item)
    }

    private func makeOverviewUnifiedSubmenu(
        model: OverviewUnifiedModel) -> NSMenu
    {
        let submenu = NSMenu()
        let spendItem = NSMenuItem(
            title: L("tab_usage_spend"),
            action: #selector(self.openUsageSpendFromMenu(_:)),
            keyEquivalent: "")
        spendItem.target = self
        submenu.addItem(spendItem)
        submenu.addItem(.separator())
        for row in model.quotaRows {
            let detail = row.hasError
                ? (row.errorText ?? "")
                : row.percentLabel
            let item = NSMenuItem(
                title: "\(row.displayName) · \(detail)",
                action: #selector(self.selectOverviewContributionProvider(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject =
                "\(Self.overviewRowIdentifierPrefix)\(row.provider.rawValue)"
            submenu.addItem(item)
        }
        return submenu
    }

    @objc func openUsageSpendFromMenu(_ sender: NSMenuItem) {
        self.openUsageSpendPane()
    }

    @objc func selectOverviewContributionProvider(_ sender: NSMenuItem) {
        guard let represented = sender.representedObject as? String,
              represented.hasPrefix(Self.overviewRowIdentifierPrefix)
        else {
            return
        }
        let rawProvider = String(represented.dropFirst(Self.overviewRowIdentifierPrefix.count))
        guard let provider = UsageProvider(rawValue: rawProvider) else { return }
        // Contribution items live inside the totals row submenu; route the switch back to the
        // root merged menu so the provider detail card replaces the whole Overview.
        let menu = self.mergedMenu ?? sender.menu
        guard let menu else { return }
        self.selectOverviewProvider(provider, menu: menu)
    }
}
