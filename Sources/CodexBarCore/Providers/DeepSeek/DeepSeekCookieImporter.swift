import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS)
import SweetCookieKit

private let deepSeekCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.deepseek]?.browserCookieOrder ?? Browser.defaultImportOrder

public enum DeepSeekCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = [
        "platform.deepseek.com",
        "deepseek.com",
    ]

    public struct SessionInfo: Sendable {
        public let session: DeepSeekPlatformSession
        public let sourceLabel: String

        public init(session: DeepSeekPlatformSession, sourceLabel: String) {
            self.session = session
            self.sourceLabel = sourceLabel
        }
    }

    nonisolated(unsafe) static var importSessionsOverrideForTesting:
        ((BrowserDetection, ((String) -> Void)?) throws -> [SessionInfo])?

    public static func importSessions(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        if let override = self.importSessionsOverrideForTesting {
            return try override(browserDetection, logger)
        }

        return try self.importSessions(
            browserDetection: browserDetection,
            logger: logger,
            loadRecords: { browserSource, query, log in
                try Self.cookieClient.codexBarRecords(
                    matching: query,
                    in: browserSource,
                    logger: log)
            })
    }

    static func importSessions(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil,
        loadRecords: (Browser, BrowserCookieQuery, ((String) -> Void)?) throws
            -> [BrowserCookieStoreRecords]) throws -> [SessionInfo]
    {
        let log: (String) -> Void = { msg in logger?("[deepseek-cookie] \(msg)") }
        var sessions: [SessionInfo] = []
        var accessDeniedHints: [String] = []
        let installed = deepSeekCookieImportOrder.cookieImportCandidates(using: browserDetection)
        let labels = installed.map(\.displayName).joined(separator: ", ")
        log("Cookie import candidates: \(labels)")

        for browserSource in installed {
            do {
                let query = BrowserCookieQuery(domains: self.cookieDomains)
                let sources = try loadRecords(browserSource, query, log)
                sessions.append(contentsOf: self.sessionInfos(from: sources, origin: query.origin))
            } catch let error as BrowserCookieError {
                BrowserCookieAccessGate.recordIfNeeded(error)
                if let hint = error.accessDeniedHint {
                    accessDeniedHints.append(hint)
                }
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        if sessions.isEmpty, !accessDeniedHints.isEmpty {
            let details = Array(Set(accessDeniedHints)).sorted().joined(separator: " ")
            throw DeepSeekSettingsError.missingCookie(details: details)
        }
        return sessions
    }

    public static func hasSession(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) -> Bool
    {
        (try? self.importSessions(browserDetection: browserDetection, logger: logger).isEmpty == false) ?? false
    }

    static func sessionInfos(
        from sources: [BrowserCookieStoreRecords],
        origin: BrowserCookieOriginStrategy = .domainBased) -> [SessionInfo]
    {
        let grouped = Dictionary(grouping: sources, by: { $0.store.profile.id })
        let sortedGroups = grouped.values.sorted { lhs, rhs in
            self.mergedLabel(for: lhs) < self.mergedLabel(for: rhs)
        }

        var sessions: [SessionInfo] = []
        for group in sortedGroups where !group.isEmpty {
            let label = self.mergedLabel(for: group)
            let mergedRecords = self.mergeRecords(group)
            guard !mergedRecords.isEmpty else { continue }
            let cookies = BrowserCookieClient.makeHTTPCookies(mergedRecords, origin: origin)
            guard let cookieHeader = DeepSeekCookieHeader.header(from: cookies) else {
                continue
            }
            let session = DeepSeekPlatformSession(cookieHeader: cookieHeader, authorizationHeader: nil)
            sessions.append(SessionInfo(session: session, sourceLabel: label))
        }
        return sessions
    }

    private static func mergedLabel(for sources: [BrowserCookieStoreRecords]) -> String {
        guard let base = sources.map(\.label).min() else {
            return "Unknown"
        }
        if base.hasSuffix(" (Network)") {
            return String(base.dropLast(" (Network)".count))
        }
        return base
    }

    private static func mergeRecords(_ sources: [BrowserCookieStoreRecords]) -> [BrowserCookieRecord] {
        let sortedSources = sources.sorted { lhs, rhs in
            self.storePriority(lhs.store.kind) < self.storePriority(rhs.store.kind)
        }
        var mergedByKey: [String: BrowserCookieRecord] = [:]
        for source in sortedSources {
            for record in source.records {
                let key = self.recordKey(record)
                if let existing = mergedByKey[key] {
                    if self.shouldReplace(existing: existing, candidate: record) {
                        mergedByKey[key] = record
                    }
                } else {
                    mergedByKey[key] = record
                }
            }
        }
        return Array(mergedByKey.values)
    }

    private static func storePriority(_ kind: BrowserCookieStoreKind) -> Int {
        switch kind {
        case .network: 0
        case .primary: 1
        case .safari: 2
        }
    }

    private static func recordKey(_ record: BrowserCookieRecord) -> String {
        "\(record.name)|\(record.domain)|\(record.path)"
    }

    private static func shouldReplace(existing: BrowserCookieRecord, candidate: BrowserCookieRecord) -> Bool {
        switch (existing.expires, candidate.expires) {
        case let (lhs?, rhs?):
            rhs > lhs
        case (nil, .some):
            true
        case (.some, nil):
            false
        case (nil, nil):
            false
        }
    }
}
#endif

public enum DeepSeekSettingsError: LocalizedError, Sendable {
    case missingCookie(details: String? = nil)
    case invalidCookie

    public var errorDescription: String? {
        switch self {
        case let .missingCookie(details):
            if let details, !details.isEmpty {
                "Missing DeepSeek platform web session. \(details)"
            } else {
                "Missing DeepSeek platform web session. Log into platform.deepseek.com in your browser, "
                    + "then refresh once (⌘R) or paste a Cookie / Authorization header in Settings."
            }
        case .invalidCookie:
            "DeepSeek platform cookie header is invalid."
        }
    }
}
