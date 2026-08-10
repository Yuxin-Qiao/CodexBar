import Foundation

extension RateWindow {
    /// The primary slot is the session lane even when a provider omits duration metadata.
    private static let sessionWindowMinutes = 5 * 60

    /// Projects the primary (session) window onto a longer binding lane when that lane is exhausted.
    ///
    /// When the total quota (weekly/monthly) is used up, session room is unusable until the longer
    /// window resets. Mirror the Codex weekly-caps-session projection generically: the returned
    /// window reads 0% remaining and carries the binding lane's reset time instead of a misleading
    /// session percentage. Returns `nil` when no longer lane is exhausted right now.
    public static func bindingProjectedPrimary(
        primary: RateWindow,
        bindingLanes: [RateWindow],
        now: Date) -> RateWindow?
    {
        let primaryMinutes = primary.windowMinutes ?? Self.sessionWindowMinutes
        let candidates = bindingLanes.filter { lane in
            guard let minutes = lane.windowMinutes, minutes > primaryMinutes else { return false }
            guard lane.remainingPercent <= 0 else { return false }
            return lane.resetsAt.map { $0 > now } ?? true
        }
        guard let binding = candidates.max(by: { ($0.windowMinutes ?? 0) < ($1.windowMinutes ?? 0) }) else {
            return nil
        }
        let reset = Self.bindingReset(primary: primary, binding: binding, now: now)
        return RateWindow(
            usedPercent: max(primary.usedPercent, 100),
            windowMinutes: primary.windowMinutes,
            resetsAt: reset.date,
            resetDescription: reset.description,
            nextRegenPercent: primary.nextRegenPercent,
            isSyntheticPlaceholder: primary.isSyntheticPlaceholder)
    }

    /// When both lanes are exhausted, the account unblocks at the later of the two resets.
    private static func bindingReset(
        primary: RateWindow,
        binding: RateWindow,
        now: Date) -> (date: Date?, description: String?)
    {
        let primaryIsExhausted = primary.remainingPercent <= 0 &&
            (primary.resetsAt.map { $0 > now } ?? true)
        guard primaryIsExhausted else {
            return (binding.resetsAt, binding.resetDescription)
        }
        guard let primaryReset = primary.resetsAt, let bindingReset = binding.resetsAt else {
            return (nil, nil)
        }
        if primaryReset > bindingReset {
            return (primaryReset, primary.resetDescription)
        }
        return (bindingReset, binding.resetDescription)
    }
}
