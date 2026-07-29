import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct SessionQuotaPersistenceTests {
    @MainActor
    final class NotifierSpy: SessionQuotaNotifying {
        private(set) var posts: [SessionQuotaTransition] = []

        func post(transition: SessionQuotaTransition, provider _: UsageProvider, badge _: NSNumber?) {
            self.posts.append(transition)
        }

        func postQuotaWarning(
            event _: QuotaWarningEvent,
            provider _: UsageProvider,
            soundEnabled _: Bool,
            onScreenAlertEnabled _: Bool)
        {}
    }

    @Test
    func `depleted session notification does not repeat after app restart`() throws {
        let suiteName = "SessionQuotaPersistenceTests-persisted-depletion"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suiteName),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.sessionQuotaNotificationsEnabled = true

        let available = Self.snapshot(usedPercent: 20)
        let depleted = Self.snapshot(usedPercent: 100)

        let firstNotifier = NotifierSpy()
        let firstStore = Self.store(settings: settings, notifier: firstNotifier)
        firstStore.handleSessionQuotaTransition(provider: .kimi, snapshot: available)
        firstStore.handleSessionQuotaTransition(provider: .kimi, snapshot: depleted)
        #expect(firstNotifier.posts == [.depleted])

        let restartedNotifier = NotifierSpy()
        let restartedStore = Self.store(settings: settings, notifier: restartedNotifier)
        restartedStore.handleSessionQuotaTransition(provider: .kimi, snapshot: depleted)
        #expect(restartedNotifier.posts.isEmpty)

        restartedStore.handleSessionQuotaTransition(provider: .kimi, snapshot: available)
        #expect(restartedNotifier.posts == [.restored])

        let nextDepletionNotifier = NotifierSpy()
        let nextStore = Self.store(settings: settings, notifier: nextDepletionNotifier)
        nextStore.handleSessionQuotaTransition(provider: .kimi, snapshot: depleted)
        #expect(nextDepletionNotifier.posts == [.depleted])
    }

    @Test
    func `new reset cycle can notify after restart even when both observations are depleted`() throws {
        let suiteName = "SessionQuotaPersistenceTests-reset-cycle"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suiteName),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.sessionQuotaNotificationsEnabled = true

        let firstNotifier = NotifierSpy()
        let firstStore = Self.store(settings: settings, notifier: firstNotifier)
        firstStore.handleSessionQuotaTransition(
            provider: .kimi,
            snapshot: Self.snapshot(usedPercent: 20, resetsAt: Date(timeIntervalSince1970: 100)))
        firstStore.handleSessionQuotaTransition(
            provider: .kimi,
            snapshot: Self.snapshot(usedPercent: 100, resetsAt: Date(timeIntervalSince1970: 100)))
        #expect(firstNotifier.posts == [.depleted])

        let restartedNotifier = NotifierSpy()
        let restartedStore = Self.store(settings: settings, notifier: restartedNotifier)
        restartedStore.handleSessionQuotaTransition(
            provider: .kimi,
            snapshot: Self.snapshot(usedPercent: 100, resetsAt: Date(timeIntervalSince1970: 200)))
        #expect(restartedNotifier.posts == [.depleted])
    }

    private static func store(
        settings: SettingsStore,
        notifier: NotifierSpy) -> UsageStore
    {
        UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)
    }

    private static func snapshot(usedPercent: Double, resetsAt: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 5 * 60,
                resetsAt: resetsAt,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
    }
}
