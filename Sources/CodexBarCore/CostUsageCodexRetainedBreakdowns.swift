import Foundation

/// Bounded presentation data from the same scan as the retained daily report. No tool bodies or event logs.
struct CostUsageCodexRetainedBreakdowns: Codable, Equatable {
    static let currentVersion = 1
    static let maximumPayloadBytes = 2 * 1024 * 1024

    struct Session: Codable, Equatable {
        let sessionID: String
        let lastActivity: Date
        let inputTokens: Int?
        let cachedInputTokens: Int?
        let outputTokens: Int?
        let reasoningTokens: Int?
        let totalTokens: Int?
        let requestCount: Int?
        let costUSD: Double?
        let modelBreakdowns: [CostUsageDailyReport.ModelBreakdown]
        let projectPath: String?
        let projectName: String?
        let title: String?
        let workingDirectory: String?
        let fileURL: URL?

        init(_ session: CostUsageSessionBreakdown) {
            self.sessionID = session.sessionID
            self.lastActivity = session.lastActivity
            self.inputTokens = session.inputTokens
            self.cachedInputTokens = session.cachedInputTokens
            self.outputTokens = session.outputTokens
            self.reasoningTokens = session.reasoningTokens
            self.totalTokens = session.totalTokens
            self.requestCount = session.requestCount
            self.costUSD = session.costUSD
            self.modelBreakdowns = session.modelBreakdowns
            self.projectPath = session.projectPath
            self.projectName = session.projectName
            self.title = session.title
            self.workingDirectory = session.workingDirectory
            self.fileURL = session.toolActivitySource?.fileURL
        }

        var value: CostUsageSessionBreakdown {
            var session = CostUsageSessionBreakdown(
                sessionID: self.sessionID,
                lastActivity: self.lastActivity,
                inputTokens: self.inputTokens,
                cachedInputTokens: self.cachedInputTokens,
                outputTokens: self.outputTokens,
                reasoningTokens: self.reasoningTokens,
                totalTokens: self.totalTokens,
                requestCount: self.requestCount,
                costUSD: self.costUSD,
                modelBreakdowns: self.modelBreakdowns,
                projectPath: self.projectPath,
                projectName: self.projectName,
                title: self.title,
                toolActivitySource: self.fileURL.map {
                    SessionToolActivitySource(fileURL: $0, sessionID: self.sessionID)
                })
            session.workingDirectory = self.workingDirectory
            return session
        }
    }

    let version: Int
    let projects: [CostUsageProjectBreakdown]
    let sessions: [Session]
    let projectSessionIDs: [String: Set<String>]
    let projectAvailability: CostUsageBreakdownAvailability

    init?(
        projects: [CostUsageProjectBreakdown],
        sessions: [CostUsageSessionBreakdown],
        projectSessionIDs: [String: Set<String>],
        projectAvailability: CostUsageBreakdownAvailability,
        maximumPayloadBytes: Int = Self.maximumPayloadBytes)
    {
        self.version = Self.currentVersion
        self.projects = projects
        self.sessions = sessions.map(Session.init)
        self.projectSessionIDs = projectSessionIDs
        self.projectAvailability = projectAvailability
        guard let data = try? JSONEncoder().encode(self), data.count <= maximumPayloadBytes else { return nil }
    }
}

extension CostUsageCodexPreviousReport {
    /// Capture all projections using one pricing context before a bounded refresh mutates the cache.
    static func capturing(
        cache: CostUsageCache,
        range: CostUsageScanner.CostUsageDayRange,
        sessionRoots: [URL],
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil,
        priorityTurns: [String: CostUsageScanner.CodexPriorityTurnMetadata]? = nil) -> Self?
    {
        let projectsAreComplete = cache.codexProjectMetadataVersion == CostUsageScanner.codexProjectMetadataVersion
        let projections = CostUsageScanner.buildCodexReportProjectionsFromCache(
            cache: cache,
            range: range,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot,
            sessionRoots: sessionRoots,
            includeProjects: projectsAreComplete,
            priorityTurns: priorityTurns)
        let membership = CostUsageStoreReadView(cache: cache, purpose: .report).projectSessionIDs(range: range)
        var classificationIsAvailable = false
        let enriched = CostUsageFetcher.codexBreakdownsWithMetadata(
            projections.sessions,
            projects: projections.projects,
            projectSessionIDs: membership,
            sessionsRoot: sessionRoots.first { $0.lastPathComponent == "sessions" } ?? sessionRoots.first,
            onClassificationAvailability: { classificationIsAvailable = $0 })
        return Self(
            report: projections.daily,
            cache: cache,
            reportSinceKey: range.sinceKey,
            reportUntilKey: range.untilKey,
            breakdowns: CostUsageCodexRetainedBreakdowns(
                projects: enriched.projects,
                sessions: enriched.sessions,
                projectSessionIDs: membership,
                projectAvailability: projectsAreComplete && classificationIsAvailable ? .complete : .unavailable))
    }

    func retainedBreakdowns(
        range: CostUsageScanner.CostUsageDayRange,
        sessionsRoot: URL?,
        environment: [String: String])
        -> (
            projects: [CostUsageProjectBreakdown],
            sessions: [CostUsageSessionBreakdown],
            projectAvailability: CostUsageBreakdownAvailability,
            sessionAvailability: CostUsageBreakdownAvailability)
    {
        // Session totals do not have per-day allocations. Never reuse wider-window detail amounts.
        guard self.scanSinceKey == range.sinceKey, self.scanUntilKey == range.untilKey,
              let breakdowns, breakdowns.version == CostUsageCodexRetainedBreakdowns.currentVersion
        else { return ([], [], .unavailable, .unavailable) }
        let enriched = CostUsageFetcher.codexBreakdownsWithMetadata(
            breakdowns.sessions.map(\.value),
            projects: breakdowns.projects,
            projectSessionIDs: breakdowns.projectSessionIDs,
            sessionsRoot: sessionsRoot,
            environment: environment,
            preserveRetainedClassification: true)
        return (enriched.projects, enriched.sessions, breakdowns.projectAvailability, .complete)
    }

    func report(in range: CostUsageScanner.CostUsageDayRange) -> CostUsageDailyReport {
        let report = self.report
        let entries = report.data.filter { $0.date >= range.sinceKey && $0.date <= range.untilKey }
        guard let lower = CostUsageScanner.parseDayKey(range.sinceKey, calendar: range.calendar),
              let until = CostUsageScanner.parseDayKey(range.untilKey, calendar: range.calendar),
              let upper = range.calendar.date(byAdding: .day, value: 1, to: until)
        else { return CostUsageDailyReport(data: [], summary: nil) }
        return CostUsageDailyReport.merged(
            [CostUsageDailyReport(
                data: entries,
                summary: nil,
                hourly: report.hourly.filter { $0.hour >= lower && $0.hour < upper },
                quotaSlices: report.quotaSlices.filter { $0.timestamp >= lower && $0.timestamp < upper })],
            calendar: range.calendar)
    }
}
