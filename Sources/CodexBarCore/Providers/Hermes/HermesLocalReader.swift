import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

// MARK: - Hermes Local Reader

// swiftlint:disable multiline_arguments multiline_parameters
public enum HermesLocalReader {
    public enum LocalStoreStatus: Sendable, Equatable {
        case present, absent, unavailable
    }

    public enum Coverage: Sendable, Equatable {
        case complete, partial, unavailable
    }

    public struct Limits: Sendable, Equatable {
        public var maxFileBytes: Int64 = 64 * 1024 * 1024
        public var maxSQLiteRows: Int = 100_000
        public var maxFiles: Int = 50
        public var duration: TimeInterval = 5
        public init() {}
    }

    public struct DailyReportResult: Sendable {
        public let report: CostUsageDailyReport
        public let coverage: Coverage

        public var isComplete: Bool {
            self.coverage == .complete
        }

        public var isAvailable: Bool {
            self.coverage == .complete || self.coverage == .partial
        }
    }

    public static func costProvenance(for entries: [CostUsageDailyReport.Entry]) -> CostProvenance {
        var hasActual = false, hasEstimate = false
        for entry in entries {
            hasActual = hasActual || entry.pricedRequestCount != nil
            hasEstimate = hasEstimate || entry.estimatedRequestCount != nil
        }
        switch (hasActual, hasEstimate) {
        case (true, true): return .mixed
        case (true, false): return .vendorMetered
        case (false, true): return .listPriceEstimate
        case (false, false): return .unknown
        }
    }

    public struct Context: Sendable {
        public let home: URL
        public let environment: [String: String]

        public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
            self.environment = environment
            if let raw = environment["HERMES_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                self.home = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
                    .standardizedFileURL
            } else if let envHome = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !envHome.isEmpty
            {
                self.home = URL(fileURLWithPath: (envHome as NSString).expandingTildeInPath, isDirectory: true)
                    .appendingPathComponent(".hermes", isDirectory: true).standardizedFileURL
            } else {
                self.home = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".hermes", isDirectory: true).standardizedFileURL
            }
        }

        public init(home: URL, environment: [String: String] = [:]) {
            self.home = home.standardizedFileURL
            self.environment = environment
        }

        public var databaseRoots: [URL] {
            guard self.home.deletingLastPathComponent().lastPathComponent != "profiles" else {
                return [self.home]
            }
            return [self.home, self.home.appendingPathComponent("profiles", isDirectory: true)]
        }
    }

    public static func hermesHomeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        Context(environment: environment).home
    }

    // MARK: - Safe Integer Helpers

    public static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let (res, ovf) = lhs.addingReportingOverflow(rhs)
        return ovf ? nil : res
    }

    public static func checkedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64? {
        let (res, ovf) = lhs.addingReportingOverflow(rhs)
        return ovf ? nil : res
    }

    public static func checkedSum(_ values: [Int64]) -> Int64? {
        var total: Int64 = 0
        for v in values {
            let (next, ovf) = total.addingReportingOverflow(v)
            guard !ovf else { return nil }
            total = next
        }
        return total
    }

    public static func checkedSum(_ values: [Int]) -> Int? {
        var total = 0
        for v in values {
            let (next, ovf) = total.addingReportingOverflow(v)
            guard !ovf else { return nil }
            total = next
        }
        return total
    }

    // MARK: - Discovery

    public static func hasLocalStore(context: Context) -> Bool {
        (try? self.discoverDatabasePaths(context: context)).map { !$0.isEmpty } ?? false
    }

    public static func localStoreStatus(context: Context) -> LocalStoreStatus {
        guard let discovery = try? self.discoverDatabasePathsWithStatus(context: context) else {
            return .unavailable
        }
        guard discovery.isComplete else { return .unavailable }
        return discovery.paths.isEmpty ? .absent : .present
    }

    public static func discoverDatabasePaths(context: Context) throws -> [URL] {
        try self.discoverDatabasePathsWithStatus(context: context).paths
    }

    private static func discoverDatabasePathsWithStatus(context: Context) throws -> (paths: [URL], isComplete: Bool) {
        var paths: [URL] = [], isComplete = true
        let fm = FileManager.default
        let defaultDB = context.home.appendingPathComponent("state.db", isDirectory: false)
        if fm.fileExists(atPath: defaultDB.path) { paths.append(defaultDB) }
        guard context.databaseRoots.count > 1 else { return (paths, isComplete) }
        let profilesDir = context.home.appendingPathComponent("profiles", isDirectory: true)
        do {
            let contents = try fm.contentsOfDirectory(
                at: profilesDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            for entry in contents.sorted(by: { $0.path < $1.path }) {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let profileDB = entry.appendingPathComponent("state.db", isDirectory: false)
                if fm.fileExists(atPath: profileDB.path) { paths.append(profileDB) }
            }
        } catch CocoaError.fileReadNoSuchFile {
            // Absence of profiles directory is normal
        } catch {
            isComplete = false
        }
        return (paths, isComplete)
    }

    // MARK: - Row Models

    private enum CostKind: Sendable, Equatable { case actual, estimated, included, unknown, mixed }
    private struct CostValue: Sendable, Equatable { let amount: Double?; let kind: CostKind }

    private struct UsageItem {
        let sessionID: String, sourceDatabase: String, model: String, billingProvider: String?
        let timestamp: Double?, apiCalls: Int64?, input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64
        let reasoning: Int64, totalTokens: Int64, costUSD: Double?, costKind: CostKind, dedupKey: String
        let sessionTotalTokens: Int64?, sessionTotalApiCalls: Int64?
    }

    private struct SMURow {
        let sessionID: String, model: String, billingProvider: String?, apiCallCount: Int64?
        let inputTokens: Int64, outputTokens: Int64, cacheReadTokens: Int64, cacheWriteTokens: Int64
        let reasoningTokens: Int64, estimatedCostUSD: Double?, actualCostUSD: Double?
        let costStatus: String?, costSource: String?, firstSeen: Double?, lastSeen: Double?
    }

    private struct SessionRow {
        let id: String, model: String?, billingProvider: String?, startedAt: Double, lastActivityAt: Double?
        let apiCallCount: Int64?, inputTokens: Int64, outputTokens: Int64, cacheReadTokens: Int64,
            cacheWriteTokens: Int64
        let reasoningTokens: Int64, estimatedCostUSD: Double?, actualCostUSD: Double?
        let costStatus: String?, costSource: String?
    }

    // MARK: - Main Report Generation

    public static func makeDailyReportWithStatus(
        context: Context,
        calendar: Calendar = .current,
        limits: Limits = Limits(),
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        checkCancellation: @escaping () throws -> Void = {}) throws -> DailyReportResult
    {
        let startTime = clock()
        var allItems: [UsageItem] = [], isComplete = true, rowCount = 0
        let discovery = try self.discoverDatabasePathsWithStatus(context: context)
        isComplete = discovery.isComplete
        guard !discovery.paths.isEmpty else {
            return DailyReportResult(
                report: CostUsageDailyReport(data: [], summary: nil),
                coverage: isComplete ? .unavailable : .partial)
        }

        do {
            for dbURL in discovery.paths.prefix(limits.maxFiles) {
                try checkCancellation()
                guard clock() - startTime < limits.duration else { isComplete = false; break }
                let (items, dbComplete) = self.scanDatabase(
                    dbURL, limits: limits, rowCount: &rowCount, checkCancellation: checkCancellation)
                allItems.append(contentsOf: items)
                if !dbComplete { isComplete = false }
                if rowCount >= limits.maxSQLiteRows { isComplete = false; break }
            }
        } catch {
            isComplete = false
        }

        return self.aggregate(items: allItems, calendar: calendar, isComplete: isComplete)
    }

    public static func makeDailyReport(
        calendar: Calendar = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> CostUsageDailyReport
    {
        (try? self.makeDailyReportWithStatus(context: Context(environment: environment), calendar: calendar))?.report
            ?? CostUsageDailyReport(data: [], summary: nil)
    }

    // MARK: - SQLite Scanning

    #if canImport(SQLite3) || canImport(CSQLite3)
    private static func scanDatabase(
        _ url: URL, limits: Limits, rowCount: inout Int,
        checkCancellation: () throws -> Void) -> (items: [UsageItem], isComplete: Bool)
    {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64,
              size <= limits.maxFileBytes else { return ([], false) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) ==
            SQLITE_OK,
            let db
        else {
            if let db { sqlite3_close(db) }
            return ([], false)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        guard sqlite3_exec(db, "BEGIN DEFERRED", nil, nil, nil) == SQLITE_OK else { return ([], false) }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }

        var smuRowsBySession: [String: [SMURow]] = [:]
        let (smuRows, smuDone) = self.readSMURows(
            db: db, limits: limits, rowCount: &rowCount, checkCancellation: checkCancellation)
        for row in smuRows {
            smuRowsBySession[row.sessionID, default: []].append(row)
        }

        var sessionRowsByID: [String: SessionRow] = [:]
        let (sessionRows, sDone) = self.readSessionRows(
            db: db, limits: limits, rowCount: &rowCount, checkCancellation: checkCancellation)
        for row in sessionRows {
            sessionRowsByID[row.id] = row
        }

        guard !smuRows.isEmpty || !sessionRows.isEmpty || (smuDone && sDone) else { return ([], false) }

        var sContext = SessionContext(
            sourceDatabase: url.standardizedFileURL.path,
            items: [],
            isComplete: smuDone && sDone)
        let allSessions = Set(smuRowsBySession.keys).union(sessionRowsByID.keys)

        for sessionID in allSessions {
            self.processSession(
                sessionID: sessionID,
                smu: smuRowsBySession[sessionID] ?? [],
                session: sessionRowsByID[sessionID],
                context: &sContext)
        }
        return (sContext.items, sContext.isComplete)
    }

    private static func resolveTimestamp(firstSeen: Double?, lastSeen: Double?, session: SessionRow?) -> Double? {
        if let ls = lastSeen, ls.isFinite, ls > 0 { return ls }
        if let fs = firstSeen, fs.isFinite, fs > 0 { return fs }
        if let act = session?.lastActivityAt, act.isFinite, act > 0 { return act }
        if let st = session?.startedAt, st.isFinite, st > 0 { return st }
        return nil
    }

    private static func resolveSessionTimestamp(session: SessionRow) -> Double? {
        if let la = session.lastActivityAt, la.isFinite, la > 0 { return la }
        if session.startedAt.isFinite, session.startedAt > 0 { return session.startedAt }
        return nil
    }

    private static func calculateModelCostScale(
        smu: [SMURow], sessionCost: CostValue?, modelCostTotal: Double?) -> Double?
    {
        guard let sAmt = sessionCost?.amount, let modelCostTotal,
              modelCostTotal > sAmt, modelCostTotal > 0,
              smu.allSatisfy({
                  let c = self.costValue(
                      actual: $0.actualCostUSD, estimated: $0.estimatedCostUSD, status: $0.costStatus,
                      source: $0.costSource)
                  return c.kind == sessionCost?.kind && c.amount != nil
              })
        else { return nil }
        return sAmt / modelCostTotal
    }

    private static func prefersAuthoritativeSessionCost(
        smu: [SMURow], sessionCost: CostValue?, modelCostTotal: Double?, scale: Double?) -> Bool
    {
        guard let sAmt = sessionCost?.amount else { return false }
        let hasMismatch = smu.contains {
            let c = self.costValue(
                actual: $0.actualCostUSD, estimated: $0.estimatedCostUSD, status: $0.costStatus, source: $0.costSource)
            return c.kind != sessionCost?.kind || c.amount == nil
        }
        let exceedsWithoutScale = (modelCostTotal.map { $0 > sAmt } ?? false) && scale == nil
        return hasMismatch || exceedsWithoutScale
    }

    private struct SessionContext {
        let sourceDatabase: String
        var items: [UsageItem]
        var isComplete: Bool
    }

    private static func processSession(
        sessionID: String,
        smu: [SMURow],
        session: SessionRow?,
        context: inout SessionContext)
    {
        let sessionCost = session.map {
            self.costValue(
                actual: $0.actualCostUSD,
                estimated: $0.estimatedCostUSD,
                status: $0.costStatus,
                source: $0.costSource)
        }
        var modelCostSum = 0.0, allModelCostFinite = true
        for r in smu {
            if let amt = self.costValue(
                actual: r.actualCostUSD,
                estimated: r.estimatedCostUSD,
                status: r.costStatus,
                source: r.costSource).amount
            {
                modelCostSum += amt
            } else { allModelCostFinite = false }
        }
        let modelCostTotal: Double? = (allModelCostFinite && modelCostSum.isFinite) ? modelCostSum : nil
        let scale = self.calculateModelCostScale(smu: smu, sessionCost: sessionCost, modelCostTotal: modelCostTotal)
        let authoritative = self.prefersAuthoritativeSessionCost(
            smu: smu, sessionCost: sessionCost, modelCostTotal: modelCostTotal, scale: scale)

        var smuInp: Int64 = 0, smuOut: Int64 = 0, smuCr: Int64 = 0, smuCw: Int64 = 0, smuReas: Int64 = 0
        var smuCost = 0.0, smuCostKnown = true, smuCostKind: CostKind?
        var smuCalls: Int64 = 0, smuCallsKnown = true

        for r in smu {
            let inp = max(0, r.inputTokens), out = max(0, r.outputTokens), cr = max(0, r.cacheReadTokens)
            let cw = max(0, r.cacheWriteTokens), reas = max(0, r.reasoningTokens)
            guard let rowTotal = self.checkedSum([inp, out, cr, cw]) else { context.isComplete = false; continue }

            smuInp = smuInp.addingReportingOverflow(inp).partialValue
            smuOut = smuOut.addingReportingOverflow(out).partialValue
            smuCr = smuCr.addingReportingOverflow(cr).partialValue
            smuCw = smuCw.addingReportingOverflow(cw).partialValue
            smuReas = smuReas.addingReportingOverflow(reas).partialValue

            let parsedCost = self.costValue(
                actual: r.actualCostUSD, estimated: r.estimatedCostUSD, status: r.costStatus, source: r.costSource)
            let costVal: CostValue = if authoritative {
                CostValue(amount: nil, kind: sessionCost?.kind ?? .unknown)
            } else if let scale, let amt = parsedCost.amount {
                CostValue(amount: amt * scale, kind: parsedCost.kind)
            } else {
                parsedCost
            }

            if authoritative {
                smuCostKind = self.mergedCostKind(smuCostKind, sessionCost?.kind ?? .unknown)
            } else if let cost = costVal.amount {
                smuCost += cost
                smuCostKind = self.mergedCostKind(smuCostKind, costVal.kind)
            } else {
                smuCostKnown = false
            }

            if let calls = r.apiCallCount {
                smuCalls = smuCalls.addingReportingOverflow(calls).partialValue
            } else {
                smuCallsKnown = false
            }

            let ts = self.resolveTimestamp(firstSeen: r.firstSeen, lastSeen: r.lastSeen, session: session)
            let prov = r.billingProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
            let dedup = "hermes:smu:\(sessionID):\(r.model):\(prov ?? "<null>")"
            context.items.append(UsageItem(
                sessionID: sessionID, sourceDatabase: context.sourceDatabase, model: r.model, billingProvider: prov,
                timestamp: ts, apiCalls: r.apiCallCount, input: inp, output: out, cacheRead: cr, cacheWrite: cw,
                reasoning: reas, totalTokens: rowTotal, costUSD: costVal.amount, costKind: costVal.kind,
                dedupKey: dedup, sessionTotalTokens: nil, sessionTotalApiCalls: nil))
        }

        if let s = session {
            let sInp = max(0, s.inputTokens), sOut = max(0, s.outputTokens), sCr = max(0, s.cacheReadTokens)
            let sCw = max(0, s.cacheWriteTokens), sReas = max(0, s.reasoningTokens)
            let sessionCostVal = sessionCost ?? CostValue(amount: nil, kind: .unknown)
            let sCost = sessionCostVal.amount
            let sCalls = s.apiCallCount
            let sessionTotalTokens = self.checkedSum([sInp, sOut, sCr, sCw])
            let resInp = max(0, sInp - smuInp), resOut = max(0, sOut - smuOut)
            let resCr = max(0, sCr - smuCr), resCw = max(0, sCw - smuCw), resReas = max(0, sReas - smuReas)

            let resCost: Double? = if let sCost, smuCostKnown, let smuK = smuCostKind, smuK == sessionCostVal.kind {
                max(0.0, sCost - smuCost)
            } else if smu.isEmpty {
                sCost
            } else {
                nil
            }

            let resCalls: Int64? = if let sCalls, smuCallsKnown {
                max(0, sCalls - smuCalls)
            } else if smu.isEmpty {
                sCalls
            } else {
                nil
            }

            guard let resTotal = self.checkedSum([resInp, resOut, resCr, resCw]) else { return }
            let hasResidual = resTotal > 0 || (resCost ?? 0) > 0 || (resCalls ?? 0) > 0
                || (authoritative && sCost != nil)
                || (smu.isEmpty && (sCost != nil || (sCalls ?? 0) > 0))

            if hasResidual {
                let ts = self.resolveSessionTimestamp(session: s)
                let mName = s.model?.trimmingCharacters(in: .whitespacesAndNewlines)
                let effModel = (mName?.isEmpty == false) ? mName! : "unknown"
                let prov = s.billingProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
                context.items.append(UsageItem(
                    sessionID: sessionID, sourceDatabase: context.sourceDatabase, model: effModel,
                    billingProvider: prov,
                    timestamp: ts, apiCalls: resCalls, input: resInp, output: resOut, cacheRead: resCr,
                    cacheWrite: resCw,
                    reasoning: resReas, totalTokens: resTotal, costUSD: resCost,
                    costKind: resCost == nil ? .unknown : sessionCostVal.kind, dedupKey: "hermes:res:\(sessionID)",
                    sessionTotalTokens: sessionTotalTokens, sessionTotalApiCalls: sCalls.map { max(0, $0) }))
            }
        }
    }

    private static func readSMURows(
        db: OpaquePointer, limits: Limits, rowCount: inout Int,
        checkCancellation: () throws -> Void) -> (rows: [SMURow], complete: Bool)
    {
        let sql = """
        SELECT session_id, model, billing_provider, api_call_count, input_tokens, output_tokens,
               cache_read_tokens, cache_write_tokens, reasoning_tokens, estimated_cost_usd, actual_cost_usd,
               cost_status, cost_source, first_seen, last_seen FROM session_model_usage
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return ([], false) }
        defer { sqlite3_finalize(stmt) }
        var rows: [SMURow] = [], valid = true
        while sqlite3_step(stmt) == SQLITE_ROW {
            if (try? checkCancellation()) == nil { return (rows, false) }
            rowCount += 1
            guard rowCount <= limits.maxSQLiteRows else { return (rows, false) }
            guard let sidPtr = sqlite3_column_text(stmt, 0), let mPtr = sqlite3_column_text(stmt, 1) else { continue }
            let sid = String(cString: sidPtr), model = String(cString: mPtr)
            guard !sid.isEmpty, !model.isEmpty else { continue }
            guard let inp = self.colInt64(stmt, 4), let out = self.colInt64(stmt, 5),
                  let cr = self.colInt64(stmt, 6), let cw = self.colInt64(stmt, 7),
                  let reas = self.colInt64(stmt, 8) else { valid = false; continue }

            rows.append(SMURow(
                sessionID: sid, model: model, billingProvider: self.colText(stmt, 2),
                apiCallCount: self.colInt64(stmt, 3), inputTokens: inp, outputTokens: out,
                cacheReadTokens: cr, cacheWriteTokens: cw, reasoningTokens: reas,
                estimatedCostUSD: self.colDouble(stmt, 9), actualCostUSD: self.colDouble(stmt, 10),
                costStatus: self.colText(stmt, 11), costSource: self.colText(stmt, 12),
                firstSeen: self.colDouble(stmt, 13), lastSeen: self.colDouble(stmt, 14)))
        }
        return (rows, valid)
    }

    private static func readSessionRows(
        db: OpaquePointer, limits: Limits, rowCount: inout Int,
        checkCancellation: () throws -> Void) -> (rows: [SessionRow], complete: Bool)
    {
        let sql = """
        SELECT id, model, billing_provider, started_at, last_activity_at, api_call_count,
               input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens,
               estimated_cost_usd, actual_cost_usd, cost_status, cost_source FROM sessions
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return ([], false) }
        defer { sqlite3_finalize(stmt) }
        var rows: [SessionRow] = [], valid = true
        while sqlite3_step(stmt) == SQLITE_ROW {
            if (try? checkCancellation()) == nil { return (rows, false) }
            rowCount += 1
            guard rowCount <= limits.maxSQLiteRows else { return (rows, false) }
            guard let idPtr = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: idPtr)
            guard !id.isEmpty, let startedAt = self.colDouble(stmt, 3) else { valid = false; continue }
            guard let inp = self.colInt64(stmt, 6), let out = self.colInt64(stmt, 7),
                  let cr = self.colInt64(stmt, 8), let cw = self.colInt64(stmt, 9),
                  let reas = self.colInt64(stmt, 10) else { valid = false; continue }

            rows.append(SessionRow(
                id: id, model: self.colText(stmt, 1), billingProvider: self.colText(stmt, 2),
                startedAt: startedAt, lastActivityAt: self.colDouble(stmt, 4), apiCallCount: self.colInt64(stmt, 5),
                inputTokens: inp, outputTokens: out, cacheReadTokens: cr, cacheWriteTokens: cw,
                reasoningTokens: reas, estimatedCostUSD: self.colDouble(stmt, 11), actualCostUSD: self.colDouble(
                    stmt,
                    12),
                costStatus: self.colText(stmt, 13), costSource: self.colText(stmt, 14)))
        }
        return (rows, valid)
    }

    private static func colText(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL, let p = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: p)
    }

    private static func colDouble(_ stmt: OpaquePointer, _ idx: Int32) -> Double? {
        let t = sqlite3_column_type(stmt, idx)
        guard t == SQLITE_FLOAT || t == SQLITE_INTEGER else { return nil }
        let v = sqlite3_column_double(stmt, idx)
        return v.isFinite ? v : nil
    }

    private static func colInt64(_ stmt: OpaquePointer, _ idx: Int32) -> Int64? {
        guard sqlite3_column_type(stmt, idx) == SQLITE_INTEGER else { return nil }
        let v = sqlite3_column_int64(stmt, idx)
        return v >= 0 ? v : nil
    }
    #else
    private static func scanDatabase(
        _ url: URL, limits: Limits, rowCount: inout Int,
        checkCancellation: () throws -> Void) -> (items: [UsageItem], isComplete: Bool)
    {
        ([], false)
    }
    #endif

    // MARK: - Provenance & Merging Helpers

    private static func costValue(
        actual: Double?, estimated: Double?, status: String?, source: String?) -> CostValue
    {
        let st = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let sc = source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let validAct = actual.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let validEst = estimated.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }

        if st.contains("unknown") || st.contains("unavailable") || st.contains("unpriced") || st == "n/a" {
            return CostValue(amount: nil, kind: .unknown)
        }
        if st.contains("included") || st.contains("free") || st.contains("zero") || sc.contains("included") || sc
            .contains("free")
        {
            return CostValue(amount: 0, kind: .included)
        }
        if st.contains("actual") || st.contains("metered") || st.contains("billed") || st.contains("vendor")
            || sc.contains("metered") || sc.contains("actual")
        {
            return CostValue(amount: validAct, kind: validAct == nil ? .unknown : .actual)
        }
        if st.contains("estimate") || st.contains("list") || st.contains("price") || sc.contains("estimate")
            || sc.contains("list") || sc.contains("price")
        {
            return CostValue(amount: validEst, kind: validEst == nil ? .unknown : .estimated)
        }
        if let validAct, validAct > 0 { return CostValue(amount: validAct, kind: .actual) }
        if let validEst, validEst > 0 { return CostValue(amount: validEst, kind: .estimated) }
        return CostValue(amount: nil, kind: .unknown)
    }

    private static func mergedCostKind(_ lhs: CostKind?, _ rhs: CostKind) -> CostKind {
        guard let lhs else { return rhs }
        return lhs == rhs ? lhs : .mixed
    }

    // MARK: - Aggregation & Deduplication

    private struct Accumulator {
        var input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0, reasoning: Int64 = 0
        var totalTokens: Int64 = 0, cost: Double = 0.0, hasCost = false, requestCount = 0, requestCountKnown = true
        var pricedCalls = 0, estimatedCalls = 0, unmeteredCalls = 0, unpricedCalls = 0
        var sawPriced = false, sawEstimated = false, sawUnmetered = false, sawUnpriced = false
        var breakdowns: [String: Accumulator] = [:]

        mutating func add(_ item: UsageItem) -> Bool {
            let calls = item.apiCalls.flatMap { Int(exactly: $0) }
            guard item.apiCalls == nil || calls != nil else { return false }
            let (nInp, o1) = self.input.addingReportingOverflow(item.input)
            let (nOut, o2) = self.output.addingReportingOverflow(item.output)
            let (nCr, o3) = self.cacheRead.addingReportingOverflow(item.cacheRead)
            let (nCw, o4) = self.cacheWrite.addingReportingOverflow(item.cacheWrite)
            let (nReas, o5) = self.reasoning.addingReportingOverflow(item.reasoning)
            let (nTot, o6) = self.totalTokens.addingReportingOverflow(item.totalTokens)
            guard !o1, !o2, !o3, !o4, !o5, !o6 else { return false }
            self.input = nInp; self.output = nOut; self.cacheRead = nCr; self.cacheWrite = nCw
            self.reasoning = nReas; self.totalTokens = nTot

            if let calls {
                self.requestCount = self.requestCount.addingReportingOverflow(calls).partialValue
            } else {
                self.requestCountKnown = false
            }

            if let c = item.costUSD, c.isFinite, c >= 0 {
                self.cost += c; self.hasCost = true
            }
            let units = calls ?? 1
            switch item.costKind {
            case .actual:
                self.sawPriced = true
                self.pricedCalls = self.pricedCalls.addingReportingOverflow(units).partialValue
            case .estimated:
                self.sawEstimated = true
                self.estimatedCalls = self.estimatedCalls.addingReportingOverflow(units).partialValue
            case .included:
                self.sawUnmetered = true
                self.unmeteredCalls = self.unmeteredCalls.addingReportingOverflow(units).partialValue
            case .unknown, .mixed:
                self.sawUnpriced = true
                self.unpricedCalls = self.unpricedCalls.addingReportingOverflow(units).partialValue
            }
            return true
        }
    }

    private static func normalizeTS(_ ts: Double?) -> Double? {
        guard let ts, ts.isFinite, ts > 0 else { return nil }
        return ts > 1e12 ? ts / 1000.0 : ts
    }

    private static func shouldPrefer(_ candidate: UsageItem, over current: UsageItem) -> Bool {
        let candTS = self.normalizeTS(candidate.timestamp), currTS = self.normalizeTS(current.timestamp)
        if candTS != currTS { return (candTS ?? -.infinity) > (currTS ?? -.infinity) }
        if candidate.totalTokens != current.totalTokens { return candidate.totalTokens > current.totalTokens }
        if candidate.apiCalls != current.apiCalls { return (candidate.apiCalls ?? -1) > (current.apiCalls ?? -1) }
        return (candidate.costUSD ?? -.infinity) > (current.costUSD ?? -.infinity)
    }

    private static func suppressCoveredResiduals(_ itemsByDedupKey: inout [String: UsageItem]) {
        let values = Array(itemsByDedupKey.values)
        let smuBySession = Dictionary(grouping: values.filter { $0.dedupKey.hasPrefix("hermes:smu:") }, by: \.sessionID)

        for res in values where res.dedupKey.hasPrefix("hermes:res:") {
            let candidates = (smuBySession[res.sessionID] ?? []).filter { c in
                c.sourceDatabase != res.sourceDatabase
                    && (self.normalizeTS(c.timestamp) ?? 0) >= (self.normalizeTS(res.timestamp) ?? 0)
            }
            guard !candidates.isEmpty else { continue }
            let candTokens = candidates.reduce(Int64(0)) {
                $0.addingReportingOverflow(max(0, $1.totalTokens)).partialValue
            }
            guard candTokens >= (res.sessionTotalTokens ?? res.totalTokens) else { continue }

            let candCalls = candidates.compactMap(\.apiCalls)
            if res.sessionTotalApiCalls != nil, candCalls.count != candidates.count, res.apiCalls != nil { continue }
            let unmatchCalls: Int64? = if let sCalls = res.sessionTotalApiCalls, candCalls.count == candidates.count {
                max(0, sCalls - candCalls.reduce(0, +))
            } else {
                res.apiCalls
            }

            let matchingCost = candidates.filter { $0.costKind == res.costKind }.compactMap(\.costUSD).reduce(0.0, +)
            let unmatchCost = res.costUSD.map { max(0.0, $0 - matchingCost) }

            if (unmatchCost ?? 0) <= 0, (unmatchCalls ?? 0) <= 0 {
                itemsByDedupKey.removeValue(forKey: res.dedupKey)
            } else {
                itemsByDedupKey[res.dedupKey] = UsageItem(
                    sessionID: res.sessionID, sourceDatabase: res.sourceDatabase, model: res.model,
                    billingProvider: res.billingProvider, timestamp: res.timestamp, apiCalls: unmatchCalls,
                    input: 0, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0, totalTokens: 0,
                    costUSD: unmatchCost, costKind: res.costKind, dedupKey: res.dedupKey,
                    sessionTotalTokens: res.sessionTotalTokens, sessionTotalApiCalls: res.sessionTotalApiCalls)
            }
        }
    }

    private static func aggregate(items: [UsageItem], calendar: Calendar, isComplete: Bool) -> DailyReportResult {
        var deduped: [String: UsageItem] = [:]
        for item in items {
            if let curr = deduped[item.dedupKey] {
                if self.shouldPrefer(item, over: curr) { deduped[item.dedupKey] = item }
            } else { deduped[item.dedupKey] = item }
        }
        self.suppressCoveredResiduals(&deduped)

        var dayMap: [String: Accumulator] = [:], aggComplete = isComplete

        for item in deduped.values.sorted(by: { $0.dedupKey < $1.dedupKey }) {
            guard let ts = self.normalizeTS(item.timestamp) else { aggComplete = false; continue }
            let dayKey = CostUsageLocalDay.key(from: Date(timeIntervalSince1970: ts), calendar: calendar)
            var dayAccum = dayMap[dayKey] ?? Accumulator()
            guard dayAccum.add(item) else { aggComplete = false; continue }

            var modelAccum = dayAccum.breakdowns[item.model] ?? Accumulator()
            guard modelAccum.add(item) else { aggComplete = false; continue }
            dayAccum.breakdowns[item.model] = modelAccum
            dayMap[dayKey] = dayAccum
        }

        let entries: [CostUsageDailyReport.Entry] = dayMap.map { dayKey, accum in
            let bds = accum.breakdowns.map { mName, mAccum in
                CostUsageDailyReport.ModelBreakdown(
                    modelName: mName, costUSD: mAccum.hasCost ? mAccum.cost : nil,
                    totalTokens: mAccum.totalTokens > 0 ? Int(exactly: mAccum.totalTokens) : nil,
                    requestCount: mAccum.requestCountKnown && mAccum.requestCount > 0 ? mAccum.requestCount : nil,
                    inputTokens: mAccum.input > 0 ? Int(exactly: mAccum.input) : nil,
                    outputTokens: mAccum.output > 0 ? Int(exactly: mAccum.output) : nil,
                    cacheReadTokens: mAccum.cacheRead > 0 ? Int(exactly: mAccum.cacheRead) : nil,
                    cacheCreationTokens: mAccum.cacheWrite > 0 ? Int(exactly: mAccum.cacheWrite) : nil,
                    reasoningTokens: mAccum.reasoning > 0 ? Int(exactly: mAccum.reasoning) : nil)
            }.sorted { $0.modelName < $1.modelName }

            return CostUsageDailyReport.Entry(
                date: dayKey,
                inputTokens: accum.input > 0 ? Int(exactly: accum.input) : nil,
                outputTokens: accum.output > 0 ? Int(exactly: accum.output) : nil,
                cacheReadTokens: accum.cacheRead > 0 ? Int(exactly: accum.cacheRead) : nil,
                cacheCreationTokens: accum.cacheWrite > 0 ? Int(exactly: accum.cacheWrite) : nil,
                reasoningTokens: accum.reasoning > 0 ? Int(exactly: accum.reasoning) : nil,
                totalTokens: accum.totalTokens > 0 ? Int(exactly: accum.totalTokens) : nil,
                requestCount: accum.requestCountKnown && accum.requestCount > 0 ? accum.requestCount : nil,
                costUSD: accum.hasCost ? accum.cost : nil,
                modelsUsed: bds.isEmpty ? nil : bds.map(\.modelName).sorted(),
                modelBreakdowns: bds.isEmpty ? nil : bds,
                unpricedRequestCount: accum.sawUnpriced ? accum.unpricedCalls : nil,
                unmeteredRequestCount: accum.sawUnmetered ? accum.unmeteredCalls : nil,
                estimatedRequestCount: accum.sawEstimated ? accum.estimatedCalls : nil,
                pricedRequestCount: accum.sawPriced ? accum.pricedCalls : nil)
        }.sorted { $0.date < $1.date }

        var totTokens = 0, totTokensOvf = false
        for t in entries.compactMap(\.totalTokens) {
            let (next, ovf) = totTokens.addingReportingOverflow(t)
            if ovf { totTokensOvf = true; break }
            totTokens = next
        }
        var totCost = 0.0, totCostOvf = false
        for c in entries.compactMap(\.costUSD) {
            let next = totCost + c
            if !next.isFinite { totCostOvf = true; break }
            totCost = next
        }
        if totTokensOvf || totCostOvf { aggComplete = false }

        let summary: CostUsageDailyReport.Summary? = entries.isEmpty ? nil : .init(
            totalInputTokens: nil, totalOutputTokens: nil,
            totalTokens: !totTokensOvf && !entries.compactMap(\.totalTokens).isEmpty ? totTokens : nil,
            totalCostUSD: !totCostOvf && !entries.compactMap(\.costUSD).isEmpty ? totCost : nil)

        return DailyReportResult(
            report: CostUsageDailyReport(data: entries, summary: summary),
            coverage: aggComplete ? .complete : .partial)
    }
}

// swiftlint:enable multiline_arguments multiline_parameters
