import Foundation

public enum DeepSeekProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .deepseek,
            metadata: ProviderMetadata(
                id: .deepseek,
                displayName: "DeepSeek",
                sessionLabel: "Balance",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show DeepSeek usage",
                cliName: "deepseek",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.deepSeekCookieImportOrder,
                dashboardURL: "https://platform.deepseek.com/usage",
                statusPageURL: nil,
                statusLinkURL: "https://status.deepseek.com"),
            branding: ProviderBranding(
                iconStyle: .deepseek,
                iconResourceName: "ProviderIcon-deepseek",
                color: ProviderColor(red: 0.32, green: 0.49, blue: 0.94)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "DeepSeek usage summaries need a platform.deepseek.com web session." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [DeepSeekAPITokenFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "deepseek",
                aliases: ["deep-seek", "ds"],
                versionDetector: nil))
    }
}

struct DeepSeekAPITokenFetchStrategy: ProviderFetchStrategy {
    let id: String = "deepseek.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        ProviderTokenResolver.deepseekToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = ProviderTokenResolver.deepseekToken(environment: context.env) else {
            throw DeepSeekUsageError.missingCredentials
        }

        let snapshot = try await DeepSeekUsageFetcher.fetchUsage(
            apiKey: apiKey,
            includeOptionalUsage: false)
        let enriched = try await Self.enrichUsageSnapshot(
            context: context,
            snapshot: snapshot)
        return self.makeResult(usage: enriched.toUsageSnapshot(), sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

extension DeepSeekAPITokenFetchStrategy {
    static func enrichUsageSnapshot(
        context: ProviderFetchContext,
        snapshot: DeepSeekUsageSnapshot) async throws -> DeepSeekUsageSnapshot
    {
        guard context.includeOptionalUsage else { return snapshot }
        guard context.settings?.deepseek?.cookieSource != .off else { return snapshot }

        var enriched = snapshot
        var rejectedCredentials = false
        let candidates = DeepSeekWebEnrichmentResolver.candidates(context: context)
        for candidate in candidates {
            guard !candidate.session.isEmpty else { continue }
            do {
                let summary = try await DeepSeekUsageFetcher.fetchUsageSummary(session: candidate.session)
                enriched = DeepSeekUsageSnapshot(
                    isAvailable: enriched.isAvailable,
                    currency: enriched.currency,
                    totalBalance: enriched.totalBalance,
                    grantedBalance: enriched.grantedBalance,
                    toppedUpBalance: enriched.toppedUpBalance,
                    usageSummary: summary,
                    updatedAt: enriched.updatedAt)
                DeepSeekWebEnrichmentResolver.cacheValidated(candidate)
                return enriched
            } catch DeepSeekUsageError.invalidCredentials {
                rejectedCredentials = true
                if candidate.isCached {
                    CookieHeaderCache.clear(provider: .deepseek)
                }
                continue
            } catch {
                if Task.isCancelled || error is CancellationError {
                    throw error
                }
                continue
            }
        }

        if rejectedCredentials, enriched.usageSummary == nil {
            Self.log.debug("DeepSeek platform session rejected; usage summary omitted.")
        }
        return enriched
    }

    private static let log = CodexBarLog.logger(LogCategories.deepSeekUsage)
}
