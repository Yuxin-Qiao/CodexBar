import Foundation

enum DeepSeekWebEnrichmentResolver {
    struct Candidate: Sendable {
        let session: DeepSeekPlatformSession
        let sourceLabel: String
        let shouldCache: Bool
        let isCached: Bool
    }

    static func candidates(context: ProviderFetchContext) -> [Candidate] {
        var candidates = self.explicitCandidates(context: context)
        #if os(macOS)
        if let cached = CookieHeaderCache.load(provider: .deepseek),
           let session = DeepSeekCookieHeader.session(from: cached.cookieHeader)
        {
            candidates.append(Candidate(
                session: session,
                sourceLabel: cached.sourceLabel,
                shouldCache: false,
                isCached: true))
        }
        if self.allowsBrowserCookieImport(context: context) {
            let sessions = (try? DeepSeekCookieImporter.importSessions(
                browserDetection: context.browserDetection)) ?? []
            for session in sessions {
                candidates.append(Candidate(
                    session: session.session,
                    sourceLabel: session.sourceLabel,
                    shouldCache: true,
                    isCached: false))
            }
        }
        #endif
        return self.deduplicated(candidates)
    }

    static func cacheValidated(_ candidate: Candidate) {
        guard candidate.shouldCache, let cookieHeader = candidate.session.cookieHeader else { return }
        CookieHeaderCache.store(
            provider: .deepseek,
            cookieHeader: cookieHeader,
            sourceLabel: candidate.sourceLabel)
    }

    #if os(macOS)
    static func allowsBrowserCookieImport(context: ProviderFetchContext) -> Bool {
        context.runtime == .app && ProviderInteractionContext.current == .userInitiated
    }
    #endif

    private static func explicitCandidates(context: ProviderFetchContext) -> [Candidate] {
        var candidates: [Candidate] = []
        if let settings = context.settings?.deepseek,
           settings.cookieSource != .off,
           let header = settings.manualCookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
           !header.isEmpty,
           let session = DeepSeekCookieHeader.session(from: header)
        {
            candidates.append(Candidate(
                session: session,
                sourceLabel: "settings",
                shouldCache: false,
                isCached: false))
        }
        if let raw = ProviderTokenResolver.deepseekCookie(environment: context.env),
           let session = DeepSeekCookieHeader.session(from: raw)
        {
            candidates.append(Candidate(
                session: session,
                sourceLabel: "environment",
                shouldCache: false,
                isCached: false))
        }
        return candidates
    }

    private static func deduplicated(_ candidates: [Candidate]) -> [Candidate] {
        var seen: Set<String> = []
        return candidates.filter { candidate in
            let key = [
                candidate.session.cookieHeader ?? "",
                candidate.session.authorizationHeader ?? "",
            ].joined(separator: "|")
            return seen.insert(key).inserted
        }
    }
}
