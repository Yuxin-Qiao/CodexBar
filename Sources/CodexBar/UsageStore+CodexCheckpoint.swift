import CodexBarCore
import Foundation

extension UsageStore {
    func codexCheckpointPublication(
        _ snapshot: CostUsageTokenSnapshot,
        accounting: PiSnapshotAccounting?) -> CostUsageTokenResult?
    {
        guard let previous = self.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex),
              let established = previous.snapshot,
              previous.accounting?.scope == accounting?.scope,
              let merged = established.mergingMonotonicCheckpoint(
                  snapshot, now: Date(), calendar: self.settings.costUsageBucketCalendar)
        else { return nil }
        let mergedAccounting: PiSnapshotAccounting?
        switch (previous.accounting, accounting) {
        case let (.includesPi(oldScope, native)?, .includesPi(newScope, checkpoint)?):
            guard oldScope == newScope else { return nil }
            mergedAccounting = .includesPi(
                scope: oldScope,
                native: native.mergingMonotonicCheckpoint(
                    checkpoint, now: Date(), calendar: self.settings.costUsageBucketCalendar) ?? native)
        case (.nativeOnly?, .nativeOnly?), (nil, nil), (nil, .nativeOnly?), (.nativeOnly?, nil):
            mergedAccounting = accounting
        case let (.piOnly(oldScope)?, .piOnly(newScope)?):
            guard oldScope == newScope else { return nil }
            mergedAccounting = accounting
        default:
            return nil
        }
        return CostUsageTokenResult(snapshot: merged, accounting: mergedAccounting)
    }
}
