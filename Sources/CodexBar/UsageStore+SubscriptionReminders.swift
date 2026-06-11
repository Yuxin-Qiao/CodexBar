import CodexBarCore
import Foundation

extension UsageStore {
    func handleProviderSubscriptionReminders(provider: UsageProvider) {
        let keySnapshot = self.settings.providerSubscriptionSnapshot(for: provider)
        let fromSettings = self.settings.providerSubscriptionReminderState(for: provider)
        guard let subscription = keySnapshot, subscription.hasDisplayableDate else {
            if self.providerSubscriptionReminderState[provider] != nil || fromSettings != nil {
                self.providerSubscriptionReminderState.removeValue(forKey: provider)
                self.settings.setProviderSubscriptionReminderState(for: provider, state: nil)
            }
            return
        }
        let providerName = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        let inMemoryState = self.providerSubscriptionReminderState[provider]
        let previous = inMemoryState ?? fromSettings
        let result = ProviderSubscriptionReminderLogic.evaluate(
            providerName: providerName,
            snapshot: subscription,
            previous: previous)
        self.providerSubscriptionReminderState[provider] = result.state
        if let state = result.state {
            self.settings.setProviderSubscriptionReminderState(for: provider, state: state)
        }
        for event in result.events {
            self.sessionQuotaNotifier.postProviderSubscriptionReminder(provider: provider, event: event, badge: nil)
        }
    }
}
