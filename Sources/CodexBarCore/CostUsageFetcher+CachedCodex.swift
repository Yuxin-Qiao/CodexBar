import Foundation

struct CachedCodexReportProjection {
    var reports: [CostUsageDailyReport] = []
    var projects: [CostUsageProjectBreakdown] = []
    var sessions: [CostUsageSessionBreakdown] = []
    var projectAvailability: CostUsageBreakdownAvailability = .notRequested
    var sessionAvailability: CostUsageBreakdownAvailability = .notRequested
    var nativeScanAt: Date?
    var staleSnapshotUpdatedAt: Date?
}

extension CostUsageFetcher {
    static func cachedCodexReportProjection(
        cache: CostUsageStoreReadView,
        range: CostUsageScanner.CostUsageDayRange,
        roots: [URL],
        rootsFingerprint: [String: Int64],
        cacheRoot: URL? = nil,
        includeBreakdowns: Bool = true,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        historyCoverageIsEstablished: Bool) -> CachedCodexReportProjection
    {
        var result = CachedCodexReportProjection()
        result.projectAvailability = includeBreakdowns ? .unavailable : .notRequested
        result.sessionAvailability = result.projectAvailability
        if includeBreakdowns, historyCoverageIsEstablished {
            result.projectAvailability = cache.projectMetadataVersion == CostUsageScanner.codexProjectMetadataVersion
                || cache.days.isEmpty ? .complete : .unavailable
            result.sessionAvailability = .complete
        }
        if !historyCoverageIsEstablished,
           let previous = cache.previousReport(range: range, rootsFingerprint: rootsFingerprint)
        {
            result.reports.append(previous.report(in: range))
            result.staleSnapshotUpdatedAt = previous.updatedAt
            if includeBreakdowns {
                let retained = previous.retainedBreakdowns(
                    range: range, sessionsRoot: roots.first, environment: environment)
                result.projects = retained.projects
                result.sessions = retained.sessions
                result.projectAvailability = retained.projectAvailability
                result.sessionAvailability = retained.sessionAvailability
            }
        } else if cache.timeZoneIdentifier == range.calendar.timeZone.identifier,
                  !cache.days.isEmpty, cache.roots == rootsFingerprint, !cache.windowExpandsCache(range)
        {
            let projections = cache.reports(
                range: range,
                cacheRoot: cacheRoot,
                roots: roots,
                includeBreakdowns: includeBreakdowns,
                includeProjects: cache.projectMetadataVersion == CostUsageScanner.codexProjectMetadataVersion)
            if !projections.daily.data.isEmpty {
                result.reports.append(projections.daily)
                if cache.lastScanUnixMs > 0 {
                    result.nativeScanAt = Date(timeIntervalSince1970: TimeInterval(cache.lastScanUnixMs) / 1000)
                }
                if includeBreakdowns {
                    (result.projects, result.sessions) = Self.codexBreakdownsWithMetadata(
                        projections.sessions,
                        projects: projections.projects,
                        projectSessionIDs: cache.projectSessionIDs(range: range),
                        sessionsRoot: roots.first,
                        environment: environment,
                        onClassificationAvailability: { available in
                            if !available { result.projectAvailability = .unavailable }
                        })
                }
            }
        }
        if result.reports.isEmpty, historyCoverageIsEstablished {
            // Established zero remains different from an unread or incompatible cache.
            result.reports.append(CostUsageDailyReport(data: [], summary: nil))
            if cache.lastScanUnixMs > 0 {
                result.nativeScanAt = Date(timeIntervalSince1970: TimeInterval(cache.lastScanUnixMs) / 1000)
            }
        }
        return result
    }
}
