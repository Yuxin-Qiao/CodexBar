import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct ProviderBrowsingTests {
    private func store(
        defaults: UserDefaults = InMemoryUserDefaults(),
        config: CodexBarConfig? = nil) -> SettingsStore
    {
        testSettingsStore(suiteName: "ProviderBrowsingTests", userDefaults: defaults, config: config)
    }

    private func sections(
        mode: ProviderListSortMode,
        enabled: Set<UsageProvider> = [],
        query: String = "",
        enabledOnly: Bool = false) -> [ProviderBrowserCatalog.Section]
    {
        ProviderBrowserCatalog.sections(
            providers: UsageProvider.allCases,
            mode: mode,
            enabled: enabled,
            filter: .init(query: query, enabledOnly: enabledOnly),
            displayName: { ProviderDescriptorRegistry.descriptor(for: $0).metadata.displayName })
    }

    @Test
    func `custom and alphabetic projections preserve existing behavior`() {
        let enabled: Set<UsageProvider> = [.codex, .kimi, .cursor]
        #expect(self.sections(mode: .custom).flatMap(\.providers) == UsageProvider.allCases)
        #expect(self.sections(mode: .alphabetical, enabled: enabled).flatMap(\.providers)
            == CodexBarConfig.alphabeticalProviderOrder(enablement: enabled.contains))
    }

    @Test
    func `families keep enabled and disabled services together with no duplicates`() {
        let sections = self.sections(mode: .family, enabled: [.kimi, .codex, .antigravity])
        let providers = sections.flatMap(\.providers)
        #expect(providers.count == UsageProvider.allCases.count)
        #expect(Set(providers) == Set(UsageProvider.allCases))
        #expect(Set(sections.first { $0.id == "family:company-moonshot" }?.providers ?? []) == [.kimi, .moonshot])
        #expect(Set(sections.first { $0.id == "family:company-google" }?.providers ?? [])
            == [.gemini, .antigravity, .vertexai])
        #expect(sections.first { $0.id == "provider:azureopenai" }?.title == nil)
        #expect(sections.first { $0.id == "provider:xkiro" }?.providers == [.xkiro])
        #expect(sections.first { $0.id == "provider:museai" }?.providers == [.museai])
        #expect(self.sections(mode: .family).flatMap(\.providers) == providers)
    }

    @Test(arguments: ["Google", "谷歌", "  google  "])
    func `company search finds related services in any mode`(query: String) {
        for mode in ProviderListSortMode.allCases {
            #expect(Set(self.sections(mode: mode, query: query).flatMap(\.providers))
                == [.antigravity, .gemini, .vertexai])
        }
    }

    @Test
    func `search combines company words accents and enabled filter`() {
        #expect(self.sections(mode: .family, query: "google gemíni").flatMap(\.providers) == [.gemini])
        let filtered = self.sections(mode: .family, enabled: [.kimi], query: "月之暗面", enabledOnly: true)
        #expect(filtered.first?.title == "Kimi / Moonshot")
        #expect(filtered.flatMap(\.providers) == [.kimi])
        #expect(self.sections(mode: .custom, query: "does-not-exist").isEmpty)
    }

    @Test
    func `visible move preserves hidden slots and rejects stale or invalid positions`() throws {
        let plugin = try #require(ProviderInstanceID(rawValue: "synthetic-plugin"))
        let full: [ProviderInstanceID] = [.codex, plugin, .claude, .gemini]
        let visible: [ProviderInstanceID] = [.codex, .claude, .gemini]
        #expect(ProviderOrderMutation.moving(
            visibleOrder: visible, fromOffsets: [1], toOffset: 0, in: full) == [.claude, plugin, .codex, .gemini])
        #expect(ProviderOrderMutation.moving(
            visibleOrder: visible, fromOffsets: [0, 2], toOffset: 3, in: full) == [.claude, plugin, .codex, .gemini])
        #expect(ProviderOrderMutation.moving(
            visibleOrder: visible, fromOffsets: [3], toOffset: 0, in: full) == nil)
        #expect(ProviderOrderMutation.moving(
            visibleOrder: visible, fromOffsets: [1], toOffset: 4, in: full) == nil)
        #expect(ProviderOrderMutation.moving(
            visibleOrder: visible, fromOffsets: [1], toOffset: 0, in: full.reversed()) == nil)
        #expect(ProviderOrderMutation.merging(visibleOrder: [.claude, .claude], into: full) == nil)
        #expect(ProviderOrderMutation.merging(visibleOrder: [.moonshot], into: full) == nil)
    }

    @Test(arguments: [false, true])
    func `legacy defaults keep their current order mode and survive restart`(alphabetical: Bool) {
        let defaults = InMemoryUserDefaults()
        defaults.set(alphabetical, forKey: "providersSortedAlphabetically")
        let settings = self.store(defaults: defaults)
        #expect(settings.providerListSortMode == (alphabetical ? .alphabetical : .custom))
        settings.providerListSortMode = .family
        settings.providersEnabledOnly = true
        let restarted = self.store(defaults: defaults)
        #expect(restarted.providerListSortMode == .family)
        #expect(restarted.providersEnabledOnly)
        restarted.providersSortedAlphabetically = true
        #expect(restarted.providerListSortMode == .alphabetical)
    }

    @Test
    func `browsing changes do not rewrite config or background work state`() throws {
        let settings = self.store()
        let before = try settings.configSnapshot.encodedData()
        let revision = settings.backgroundWorkSettingsRevision
        for mode in ProviderListSortMode.allCases {
            settings.providerListSortMode = mode
        }
        settings.providersEnabledOnly = true
        #expect(try settings.configSnapshot.encodedData() == before)
        #expect(settings.backgroundWorkSettingsRevision == revision)
    }

    @Test
    func `move and restore preserve provider values and undo only order`() throws {
        let settings = self.store(config: CodexBarConfig(providers: [
            ProviderConfig(id: .gemini, enabled: false, apiKey: "synthetic-gemini-key"),
            ProviderConfig(id: .codex, enabled: true),
        ]))
        let original = settings.configSnapshot.providers.map(\.id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let beforeByID = Dictionary(uniqueKeysWithValues: settings.configSnapshot.providers.map {
            ($0.id, try? encoder.encode($0))
        })
        settings.providerListSortMode = .family
        #expect(settings.restoreDefaultProviderOrder())
        #expect(settings.providerListSortMode == .custom)
        #expect(settings.configSnapshot.providers.map(\.id) == UsageProvider.allCases.map(\.instanceID))
        for entry in settings.configSnapshot.providers {
            #expect(try encoder.encode(entry) == beforeByID[entry.id])
        }
        settings.updateProviderConfig(provider: .gemini) { $0.apiKey = "synthetic-updated-key" }
        #expect(settings.undoProviderOrderChange())
        #expect(settings.configSnapshot.providers.map(\.id) == original)
        #expect(settings.configSnapshot.providerConfig(for: .gemini)?.apiKey == "synthetic-updated-key")
        #expect(settings.providerListSortMode == .family)
        #expect(!settings.canUndoProviderOrderChange)

        settings.providerListSortMode = .custom
        let visible = settings.orderedFirstPartyProviders().map(\.instanceID)
        #expect(settings.moveVisibleProviders(visible, fromOffsets: [0], toOffset: visible.count))
        #expect(settings.undoProviderOrderChange())
        #expect(settings.configSnapshot.providers.map(\.id) == original)
    }

    @Test
    func `stale undo cannot overwrite an external order or a later mode choice`() {
        let settings = self.store()
        let initial = settings.orderedFirstPartyProviders().map(\.instanceID)
        #expect(settings.moveVisibleProviders(initial, fromOffsets: [0], toOffset: 3))
        settings.providerListSortMode = .family
        #expect(settings.restoreDefaultProviderOrder())
        settings.providerListSortMode = .alphabetical
        #expect(settings.undoProviderOrderChange())
        #expect(settings.providerListSortMode == .alphabetical)
        settings.providerListSortMode = .custom
        #expect(settings.restoreDefaultProviderOrder())
        settings.setProviderOrder(initial.reversed())
        #expect(!settings.undoProviderOrderChange())
    }

    @Test
    func `native undo rejects a callback for an older action`() throws {
        let settings = self.store()
        #expect(settings.moveVisibleProviders(
            settings.orderedFirstPartyProviders().map(\.instanceID), fromOffsets: [0], toOffset: 3))
        let oldAction = try #require(settings.providerOrderUndo?.id)
        #expect(settings.moveVisibleProviders(
            settings.orderedFirstPartyProviders().map(\.instanceID), fromOffsets: [0], toOffset: 3))
        let latest = settings.configSnapshot.providers.map(\.id)
        #expect(!settings.undoProviderOrderChange(matching: oldAction))
        #expect(settings.configSnapshot.providers.map(\.id) == latest)
        let newAction = try #require(settings.providerOrderUndo?.id)
        #expect(settings.undoProviderOrderChange(matching: newAction))
    }

    @Test
    func `native undo keeps only the latest order action and clears stale menu commands`() {
        let settings = self.store()
        let manager = UndoManager()
        manager.groupsByEvent = false
        let initial = settings.orderedFirstPartyProviders().map(\.instanceID)
        #expect(settings.moveVisibleProviders(initial, fromOffsets: [0], toOffset: 3))
        let afterFirst = settings.configSnapshot.providers.map(\.id)
        manager.beginUndoGrouping()
        settings.registerProviderOrderUndo(in: manager)
        manager.endUndoGrouping()
        #expect(manager.canUndo)
        #expect(settings.moveVisibleProviders(
            settings.orderedFirstPartyProviders().map(\.instanceID), fromOffsets: [0], toOffset: 3))
        manager.beginUndoGrouping()
        settings.registerProviderOrderUndo(in: manager)
        manager.endUndoGrouping()
        manager.undo()
        #expect(settings.configSnapshot.providers.map(\.id) == afterFirst)
        #expect(!manager.canUndo)
        #expect(!settings.canUndoProviderOrderChange)

        #expect(settings.restoreDefaultProviderOrder())
        manager.beginUndoGrouping()
        settings.registerProviderOrderUndo(in: manager)
        manager.endUndoGrouping()
        #expect(settings.undoProviderOrderChange())
        #expect(!manager.canUndo)

        #expect(settings.restoreDefaultProviderOrder())
        manager.beginUndoGrouping()
        settings.registerProviderOrderUndo(in: manager)
        manager.endUndoGrouping()
        settings.setProviderOrder(initial.reversed())
        #expect(!manager.canUndo)
        #expect(!settings.canUndoProviderOrderChange)
    }

    @Test
    func `automatic or filtered views reject reorder`() {
        let settings = self.store()
        let visible = settings.orderedFirstPartyProviders().map(\.instanceID)
        settings.providerListSortMode = .family
        #expect(!settings.moveVisibleProviders(visible, fromOffsets: [0], toOffset: 2))
        settings.providerListSortMode = .custom
        settings.providersEnabledOnly = true
        #expect(!settings.moveVisibleProviders(visible, fromOffsets: [0], toOffset: 2))
    }

    @Test
    func `unknown plugin payload survives restoring and undoing order`() throws {
        let config = try CodexBarConfig.decode(from: Data(#"""
        {"version":1,"providers":[
          {"id":"gemini","enabled":false,"apiKey":"synthetic-key"},
          {"id":"retired-plugin","enabled":true,"opaque":{"large":123456789012345678901234567890}},
          {"id":"codex","enabled":true}
        ]}
        """#.utf8))
        let settings = self.store(config: config)
        #expect(settings.restoreDefaultProviderOrder())
        #expect(settings.undoProviderOrderChange())
        let data = try settings.configSnapshot.encodedData()
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("123456789012345678901234567890"))
        #expect(json.contains("retired-plugin"))
        #expect(settings.configSnapshot.unavailableProviders.first?.index == 1)
    }

    @Test
    func `portable mode round trips while filters remain local and old imports override it`() throws {
        let settings = self.store()
        settings.providerListSortMode = .family
        settings.providersEnabledOnly = true
        let document = try PreferencesDocument(data: settings.exportPreferences().encoded())
        #expect(try document.value("providerListSortMode", as: String.self) == "family")
        #expect(try document.value("providersEnabledOnly", as: Bool.self) == nil)
        let target = self.store()
        try target.importPreferences(document)
        #expect(target.providerListSortMode == .family)
        #expect(!target.providersEnabledOnly)
        var legacy = PreferencesDocument()
        try legacy.set("providersSortedAlphabetically", true)
        try target.importPreferences(legacy)
        #expect(target.providerListSortMode == .alphabetical)
    }

    @Test
    func `queued legacy import overrides a new mode`() throws {
        let defaults = InMemoryUserDefaults()
        let settings = self.store(defaults: defaults)
        var current = PreferencesDocument()
        try current.set("providerListSortMode", "family")
        var legacy = PreferencesDocument()
        try legacy.set("providersSortedAlphabetically", false)
        try current.queueImport(in: defaults)
        try legacy.queueImport(in: defaults)
        settings.consumePendingPreferencesImport()
        #expect(settings.providerListSortMode == .custom)
        try legacy.queueImport(in: defaults)
        try current.queueImport(in: defaults)
        settings.consumePendingPreferencesImport()
        #expect(settings.providerListSortMode == .family)
    }

    @Test
    func `old or unknown cloud modes do not clear an established new choice`() throws {
        let settings = self.store()
        var legacy = settings.syncedPreferences
        legacy.providerListSortMode = nil
        legacy.providersSortedAlphabetically = true
        let oldData = try JSONEncoder().encode(legacy)
        #expect(try JSONDecoder().decode(SyncedPreferences.self, from: oldData).providerListSortMode == nil)
        settings.applySyncedPreferences(legacy)
        #expect(settings.providerListSortMode == .alphabetical)
        settings.providerListSortMode = .family
        settings.applySyncedPreferences(legacy)
        #expect(settings.providerListSortMode == .family)
        legacy.providerListSortMode = "future-mode"
        settings.applySyncedPreferences(legacy)
        #expect(settings.providerListSortMode == .family)
        var invalid = PreferencesDocument()
        try invalid.set("providerListSortMode", "future-mode")
        #expect(throws: (any Error).self) { try invalid.validate() }
    }
}
