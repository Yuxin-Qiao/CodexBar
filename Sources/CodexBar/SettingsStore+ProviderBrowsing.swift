import CodexBarCore
import Foundation

struct ProviderOrderUndo {
    let id = UUID()
    let before: [ProviderInstanceID]
    let after: [ProviderInstanceID]
    var restoreMode: ProviderListSortMode?
}

extension SettingsStore {
    var providerListSortMode: ProviderListSortMode {
        get {
            ProviderListSortMode.resolved(
                rawValue: self.defaultsState.providerListSortModeRaw,
                alphabetical: self.defaultsState.providersSortedAlphabetically)
        }
        set {
            if newValue != self.providerListSortMode { self.providerOrderUndo?.restoreMode = nil }
            self.setDefault(\.providerListSortModeRaw, newValue.rawValue, key: "providerListSortMode")
            self.setDefault(
                \.providersSortedAlphabetically, newValue == .alphabetical, key: "providersSortedAlphabetically")
        }
    }

    var providersEnabledOnly: Bool {
        get { self.defaultsState.providersEnabledOnly }
        set { self.setDefault(\.providersEnabledOnly, newValue, key: "providersEnabledOnly") }
    }

    var canUndoProviderOrderChange: Bool {
        guard let undo = self.providerOrderUndo else { return false }
        return self.configSnapshot.providers.map(\.id) == undo.after
    }

    @discardableResult
    func moveVisibleProviders(
        _ visibleOrder: [ProviderInstanceID],
        fromOffsets: IndexSet,
        toOffset: Int) -> Bool
    {
        guard self.providerListSortMode == .custom, !self.providersEnabledOnly else { return false }
        let before = self.configSnapshot.providers.map(\.id)
        guard let after = ProviderOrderMutation.moving(
            visibleOrder: visibleOrder, fromOffsets: fromOffsets, toOffset: toOffset, in: before),
            after != before
        else { return false }
        self.setProviderOrder(after)
        self.providerOrderUndo = ProviderOrderUndo(
            before: before, after: self.configSnapshot.providers.map(\.id), restoreMode: nil)
        return true
    }

    @discardableResult
    func restoreDefaultProviderOrder() -> Bool {
        let before = self.configSnapshot.providers.map(\.id)
        let present = Set(before)
        let defaults = UsageProvider.allCases.map(\.instanceID).filter { present.contains($0) }
        let mode = self.providerListSortMode
        guard let after = ProviderOrderMutation.merging(visibleOrder: defaults, into: before),
              after != before || mode != .custom
        else { return false }
        self.setProviderOrder(after)
        self.providerListSortMode = .custom
        self.providerOrderUndo = ProviderOrderUndo(
            before: before, after: self.configSnapshot.providers.map(\.id), restoreMode: mode)
        return true
    }

    func registerProviderOrderUndo(in manager: UndoManager?) {
        self.providerOrderUndoManager?.removeAllActions(withTarget: self)
        self.providerOrderUndoManager = manager
        guard let manager, let actionID = self.providerOrderUndo?.id else { return }
        manager.removeAllActions(withTarget: self)
        manager.registerUndo(withTarget: self) { settings in
            MainActor.assumeIsolated { settings.undoProviderOrderChange(matching: actionID) }
        }
        manager.setActionName(L("Change provider order"))
    }

    func clearProviderOrderUndo() {
        self.providerOrderUndo = nil
        if let manager = self.providerOrderUndoManager, !manager.isUndoing, !manager.isRedoing {
            manager.removeAllActions(withTarget: self)
        }
        self.providerOrderUndoManager = nil
    }

    @discardableResult
    func undoProviderOrderChange(matching actionID: UUID? = nil) -> Bool {
        guard self.canUndoProviderOrderChange, let undo = self.providerOrderUndo,
              actionID == nil || actionID == undo.id
        else { return false }
        self.clearProviderOrderUndo()
        self.setProviderOrder(undo.before)
        if let mode = undo.restoreMode { self.providerListSortMode = mode }
        return true
    }
}
