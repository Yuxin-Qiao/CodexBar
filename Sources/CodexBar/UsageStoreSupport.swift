import CodexBarCore
import Foundation

enum ProviderStatusIndicator: String {
    case none
    case minor
    case major
    case critical
    case maintenance
    case unknown

    var hasIssue: Bool {
        switch self {
        case .none: false
        default: true
        }
    }

    var label: String {
        switch self {
        case .none: L("status_operational")
        case .minor: L("status_partial_outage")
        case .major: L("status_major_outage")
        case .critical: L("status_critical_issue")
        case .maintenance: L("status_maintenance")
        case .unknown: L("status_unknown")
        }
    }
}

struct ProviderStatus {
    let indicator: ProviderStatusIndicator
    let description: String?
    let updatedAt: Date?
}

/// A single component/service row on a statuspage.io-style status page
/// (e.g. "Codex API", "CLI", "FedRAMP") with its current state. A row with non-empty
/// `children` is a component group and renders as an expandable dropdown.
struct ProviderStatusComponent: Identifiable, Equatable {
    let id: String
    let name: String
    let indicator: ProviderStatusIndicator
    /// Raw provider status. The display label is localized when the row renders so changing
    /// the app language does not require another network refresh.
    let status: String
    /// Child rows for a component group; empty for leaf components.
    var children: [ProviderStatusComponent] = []

    var isGroup: Bool {
        !self.children.isEmpty
    }

    var statusLabel: String {
        Self.label(forStatuspageStatus: self.status)
    }

    /// Maps a statuspage.io component `status` string to our indicator + display label.
    static func indicator(forStatuspageStatus status: String) -> ProviderStatusIndicator {
        switch status {
        case "operational": .none
        case "degraded_performance": .minor
        case "partial_outage": .major
        case "major_outage", "full_outage": .critical
        case "under_maintenance": .maintenance
        default: .unknown
        }
    }

    static func label(forStatuspageStatus status: String) -> String {
        switch status {
        case "operational": L("status_operational")
        case "degraded_performance": L("status_degraded")
        case "partial_outage": L("status_partial_outage")
        case "major_outage", "full_outage": L("status_major_outage")
        case "under_maintenance": L("status_maintenance")
        default: L("status_unknown")
        }
    }
}


enum StatusUptimeDaySeverity: Equatable, Comparable {
    case operational, degraded, partialOutage, majorOutage
    private var rank: Int { switch self { case .operational: 0; case .degraded: 1; case .partialOutage: 2; case .majorOutage: 3 } }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
    static func severity(forStatuspageStatus status: String) -> Self {
        switch status { case "operational": .operational; case "degraded_performance": .degraded
        case "partial_outage": .partialOutage; case "major_outage", "full_outage": .majorOutage; default: .operational }
    }
    var downtimeWeight: Double { switch self { case .operational, .degraded: 0; case .partialOutage: 0.5; case .majorOutage: 1 } }
}
struct StatusUptimeDay: Identifiable, Equatable { let date: Date; let severity: StatusUptimeDaySeverity; var id: Date { date } }
struct StatusComponentUptime: Identifiable, Equatable {
    let id, name: String; let indicator: ProviderStatusIndicator; let days: [StatusUptimeDay]; let uptimePercent: Double
}
struct StatuspageIncident: Decodable, Equatable {
    struct Component: Decodable, Equatable { let id: String }
    struct Update: Decodable, Equatable {
        struct AffectedComponent: Decodable, Equatable {
            let code: String; let oldStatus, newStatus: String?
            enum CodingKeys: String, CodingKey { case code; case oldStatus = "old_status"; case newStatus = "new_status" }
        }
        let createdAt: Date?; let affectedComponents: [AffectedComponent]?
        enum CodingKeys: String, CodingKey { case createdAt = "created_at"; case affectedComponents = "affected_components" }
    }
    let id: String; let impact: String?; let startedAt, resolvedAt: Date?; let components: [Component]?; let incidentUpdates: [Update]?
    enum CodingKeys: String, CodingKey { case id, impact, components; case startedAt = "started_at"; case resolvedAt = "resolved_at"; case incidentUpdates = "incident_updates" }
}
enum StatuspageUptimeBuilder {
    static let dayCount = 30
    private static var utcCalendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    static func buildComponentUptimes(components: [ProviderStatusComponent], incidents: [StatuspageIncident], now: Date = Date(), calendar: Calendar = utcCalendar) -> [StatusComponentUptime] {
        let leaves = components.flatMap { $0.isGroup ? $0.children : [$0] }; guard !leaves.isEmpty else { return [] }
        let todayStart = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -(dayCount - 1), to: todayStart) else { return [] }
        let windowEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now
        return leaves.map { component in
            let dayStarts = (0..<dayCount).compactMap { calendar.date(byAdding: .day, value: $0, to: windowStart) }
            let days = dayStarts.map { dayStart -> StatusUptimeDay in
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
                return StatusUptimeDay(date: dayStart, severity: worstSeverity(componentID: component.id, interval: dayStart..<dayEnd, incidents: incidents, now: now))
            }
            return StatusComponentUptime(id: component.id, name: component.name, indicator: component.indicator, days: days,
                uptimePercent: uptimePercent(componentID: component.id, window: windowStart..<windowEnd, incidents: incidents, now: now, calendar: calendar))
        }
    }
    private static func worstSeverity(componentID: String, interval: Range<Date>, incidents: [StatuspageIncident], now: Date) -> StatusUptimeDaySeverity {
        var worst: StatusUptimeDaySeverity = .operational
        for item in incidents where overlapsIncident(item, interval: interval, now: now) {
            for segment in statusSegments(for: componentID, in: item, now: now) where overlaps(segment.start..<segment.end, with: interval) { worst = max(worst, segment.severity) }
        }
        return worst
    }
    private static func uptimePercent(componentID: String, window: Range<Date>, incidents: [StatuspageIncident], now: Date, calendar: Calendar) -> Double {
        let total = window.upperBound.timeIntervalSince(window.lowerBound); guard total > 0 else { return 100 }
        var downtime: TimeInterval = 0; var cursor = window.lowerBound
        while cursor < window.upperBound {
            let sliceEnd = min(calendar.date(byAdding: .hour, value: 1, to: cursor) ?? window.upperBound, window.upperBound)
            downtime += sliceEnd.timeIntervalSince(cursor) * worstSeverity(componentID: componentID, interval: cursor..<sliceEnd, incidents: incidents, now: now).downtimeWeight
            cursor = sliceEnd
        }
        return ((max(0, min(1, 1 - downtime / total))) * 10000).rounded() / 100
    }
    private struct StatusSegment { let start, end: Date; let severity: StatusUptimeDaySeverity }
    private static func statusSegments(for componentID: String, in item: StatuspageIncident, now: Date) -> [StatusSegment] {
        let incidentStart = item.startedAt ?? item.incidentUpdates?.compactMap(\.createdAt).min()
        let incidentEnd = item.resolvedAt ?? now
        guard let incidentStart, incidentStart < incidentEnd else { return [] }
        let updates = (item.incidentUpdates ?? []).sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        var segments: [StatusSegment] = []; var current = StatusUptimeDaySeverity.operational; var segmentStart = incidentStart; var hasUpdates = false
        for update in updates {
            guard let updateAt = update.createdAt, updateAt > incidentStart, updateAt <= incidentEnd, let affected = update.affectedComponents?.first(where: { $0.code == componentID }) else { continue }
            hasUpdates = true
            let previous = affected.oldStatus.map { StatusUptimeDaySeverity.severity(forStatuspageStatus: $0) } ?? current
            if updateAt > segmentStart { segments.append(.init(start: segmentStart, end: updateAt, severity: previous)) }
            current = StatusUptimeDaySeverity.severity(forStatuspageStatus: affected.newStatus ?? "operational"); segmentStart = updateAt
        }
        if segmentStart < incidentEnd { segments.append(.init(start: segmentStart, end: incidentEnd, severity: current)) }
        if !hasUpdates, item.components?.contains(where: { $0.id == componentID }) == true { segments.append(.init(start: incidentStart, end: incidentEnd, severity: severity(fromImpact: item.impact))) }
        return segments
    }
    private static func severity(fromImpact impact: String?) -> StatusUptimeDaySeverity { switch impact?.lowercased() { case "critical": .majorOutage; case "major": .partialOutage; case "minor": .degraded; default: .degraded } }
    private static func overlapsIncident(_ item: StatuspageIncident, interval: Range<Date>, now: Date) -> Bool {
        let start = item.startedAt ?? item.incidentUpdates?.compactMap(\.createdAt).min() ?? interval.lowerBound
        return overlaps(start..<(item.resolvedAt ?? now), with: interval)
    }
    private static func overlaps(_ lhs: Range<Date>, with rhs: Range<Date>) -> Bool { lhs.lowerBound < rhs.upperBound && rhs.lowerBound < lhs.upperBound }
}

/// Tracks consecutive failures so we can ignore a single flake when we previously had fresh data.
struct ConsecutiveFailureGate {
    private(set) var streak: Int = 0

    mutating func recordSuccess() {
        self.streak = 0
    }

    mutating func reset() {
        self.streak = 0
    }

    /// Returns true when the caller should surface the error to the UI.
    mutating func shouldSurfaceError(onFailureWithPriorData hadPriorData: Bool) -> Bool {
        self.streak += 1
        if hadPriorData, self.streak == 1 { return false }
        return true
    }
}

#if DEBUG
extension UsageStore {
    func _setSnapshotForTesting(_ snapshot: UsageSnapshot?, provider: UsageProvider) {
        self.snapshots[provider] = snapshot?.scoped(to: provider)
    }

    func _setTokenSnapshotForTesting(_ snapshot: CostUsageTokenSnapshot?, provider: UsageProvider) {
        self.tokenSnapshots[provider] = snapshot
    }

    func _setTokenErrorForTesting(_ error: String?, provider: UsageProvider) {
        self.tokenErrors[provider] = error
    }

    func _setErrorForTesting(_ error: String?, provider: UsageProvider) {
        self.errors[provider] = error
    }

    func _setKnownLimitsAvailabilityForTesting(
        _ availability: UsageLimitsAvailability?,
        provider: UsageProvider)
    {
        self.knownLimitsAvailabilityByProvider[provider] = availability
    }

    func _setCodexHistoricalDatasetForTesting(_ dataset: CodexHistoricalDataset?, accountKey: String? = nil) {
        self.codexHistoricalDataset = dataset
        self.codexHistoricalDatasetAccountKey = accountKey
        self.historicalPaceRevision += 1
    }
}
#endif
