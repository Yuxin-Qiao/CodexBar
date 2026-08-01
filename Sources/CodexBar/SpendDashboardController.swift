import CodexBarCore
import CryptoKit
import Foundation
import Observation

struct SpendDashboardConfiguration: Equatable, Sendable {
    let costUsageEnabled: Bool
    let preferredCurrencyCode: String
    let providerIDs: [String]
    let codexAccountIdentities: [String]
    let codexAccountDisplayNames: [String: String]
    let sourceOwnershipFingerprints: [String]
    let sourceRevisions: [String]

    init(
        costUsageEnabled: Bool,
        preferredCurrencyCode: String = "auto",
        providerIDs: [String],
        codexAccountIdentities: [String],
        codexAccountDisplayNames: [String: String] = [:],
        sourceOwnershipFingerprints: [String] = [],
        sourceRevisions: [String] = [])
    {
        self.costUsageEnabled = costUsageEnabled
        self.preferredCurrencyCode = preferredCurrencyCode
        self.providerIDs = providerIDs
        self.codexAccountIdentities = codexAccountIdentities
        self.codexAccountDisplayNames = codexAccountDisplayNames
        self.sourceOwnershipFingerprints = sourceOwnershipFingerprints
        self.sourceRevisions = sourceRevisions
    }
}

struct CodexSpendScanRequest: Equatable, Sendable {
    let id: String
    let displayName: String
    let source: CodexActiveSource
    let homePath: String
    let authFingerprint: String?
    let authFileWasReadable: Bool
    let cacheIdentity: String
}

struct LocalSpendHistoryRequest: Equatable, Sendable {
    let source: ProviderLocalHistorySource
    let provider: UsageProvider
    let homePath: String
}

enum SpendDashboardRequestBuildMode: Equatable, Sendable {
    case refreshMissing
    case forceRefresh
    case captureOnly

    var forcesLoader: Bool {
        self == .forceRefresh
    }

    func shouldRefresh(hasPublication: Bool) -> Bool {
        switch self {
        case .refreshMissing: !hasPublication
        case .forceRefresh: true
        case .captureOnly: false
        }
    }
}

struct SpendDashboardLoadRequest: Sendable {
    let configuration: SpendDashboardConfiguration
    let capturedInputs: [SpendDashboardModel.ProviderInput]
    let unavailableSourceIDs: Set<String>
    let confirmedEmptySourceIDs: Set<String>
    let codexRequests: [CodexSpendScanRequest]
    let localHistoryRequests: [LocalSpendHistoryRequest]
    let now: Date
    let force: Bool

    var kimiCodeHomePath: String? {
        self.localHistoryRequests.first { $0.source == .kimiCode }?.homePath
    }

    var geminiCLIHomePath: String? {
        self.localHistoryRequests.first { $0.source == .geminiCLI }?.homePath
    }

    var openCodeDataHomePath: String? {
        self.localHistoryRequests.first { $0.source == .openCode }?.homePath
    }

    var miniMaxHomePath: String? {
        self.localHistoryRequests.first { $0.source == .miniMax }?.homePath
    }

    var antigravityHomePath: String? {
        self.localHistoryRequests.first { $0.source == .antigravity }?.homePath
    }

    var qwenCodeHomePath: String? {
        self.localHistoryRequests.first { $0.source == .qwenCode }?.homePath
    }

    init(
        configuration: SpendDashboardConfiguration,
        capturedInputs: [SpendDashboardModel.ProviderInput],
        unavailableSourceIDs: Set<String>,
        confirmedEmptySourceIDs: Set<String> = [],
        codexRequests: [CodexSpendScanRequest],
        localHistoryRequests: [LocalSpendHistoryRequest]? = nil,
        kimiCodeHomePath: String? = nil,
        geminiCLIHomePath: String? = nil,
        openCodeDataHomePath: String? = nil,
        miniMaxHomePath: String? = nil,
        antigravityHomePath: String? = nil,
        now: Date,
        force: Bool)
    {
        self.configuration = configuration
        self.capturedInputs = capturedInputs
        self.unavailableSourceIDs = unavailableSourceIDs
        self.confirmedEmptySourceIDs = confirmedEmptySourceIDs
        self.codexRequests = codexRequests
        self.localHistoryRequests = localHistoryRequests ?? [
            kimiCodeHomePath.map {
                LocalSpendHistoryRequest(source: .kimiCode, provider: .kimi, homePath: $0)
            },
            geminiCLIHomePath.map {
                LocalSpendHistoryRequest(source: .geminiCLI, provider: .gemini, homePath: $0)
            },
            openCodeDataHomePath.map {
                LocalSpendHistoryRequest(source: .openCode, provider: .opencode, homePath: $0)
            },
            miniMaxHomePath.map {
                LocalSpendHistoryRequest(source: .miniMax, provider: .minimax, homePath: $0)
            },
            antigravityHomePath.map {
                LocalSpendHistoryRequest(source: .antigravity, provider: .antigravity, homePath: $0)
            },
        ].compactMap(\.self)
        self.now = now
        self.force = force
    }
}

struct SpendDashboardLoadResult: Sendable {
    let inputs: [SpendDashboardModel.ProviderInput]
    let failedSourceIDs: Set<String>
    let invalidatedSourceIDs: Set<String>

    init(
        inputs: [SpendDashboardModel.ProviderInput],
        failedSourceIDs: Set<String>,
        invalidatedSourceIDs: Set<String> = [])
    {
        self.inputs = inputs
        self.failedSourceIDs = failedSourceIDs
        self.invalidatedSourceIDs = invalidatedSourceIDs
    }

    var failedSourceCount: Int {
        self.failedSourceIDs.count
    }
}

struct CodexSpendSnapshotLoadContext: Sendable {
    let account: CodexSpendScanRequest
    let cacheRoot: URL
    let now: Date
    let force: Bool
    let historyDays: Int
    let refreshPricingInBackground: Bool
    let includePiSessions: Bool
}

struct KimiCodeSpendSnapshotLoadContext: Sendable {
    let homePath: String
    let now: Date
    let historyDays: Int
}

struct GeminiSpendSnapshotLoadContext: Sendable {
    let homePath: String
    let now: Date
    let historyDays: Int
}

struct OpenCodeSpendSnapshotLoadContext: Sendable {
    let homePath: String
    let now: Date
    let historyDays: Int
}

struct MiniMaxSpendSnapshotLoadContext: Sendable {
    let homePath: String
    let now: Date
    let historyDays: Int
}

struct AntigravitySpendSnapshotLoadContext: Sendable {
    let homePath: String
    let now: Date
    let historyDays: Int
}

struct QwenCodeSpendSnapshotLoadContext: Sendable {
    let homePath: String
    let now: Date
    let historyDays: Int
}

enum SpendDashboardSource {
    typealias CodexSnapshotLoader = @Sendable (CodexSpendSnapshotLoadContext) async throws
        -> CostUsageTokenSnapshot
    typealias KimiCodeSnapshotLoader = @Sendable (KimiCodeSpendSnapshotLoadContext) async throws
        -> CostUsageTokenSnapshot?
    typealias GeminiSnapshotLoader = @Sendable (GeminiSpendSnapshotLoadContext) async throws
        -> CostUsageTokenSnapshot?
    typealias OpenCodeSnapshotLoader = @Sendable (OpenCodeSpendSnapshotLoadContext) async throws
        -> CostUsageTokenSnapshot?
    typealias MiniMaxSnapshotLoader = @Sendable (MiniMaxSpendSnapshotLoadContext) async throws
        -> CostUsageTokenSnapshot?
    typealias AntigravitySnapshotLoader = @Sendable (AntigravitySpendSnapshotLoadContext) async throws
        -> CostUsageTokenSnapshot?
    typealias QwenCodeSnapshotLoader = @Sendable (QwenCodeSpendSnapshotLoadContext) async throws
        -> CostUsageTokenSnapshot?

    static let scanDays = 365

    @MainActor
    static func configuration(settings: SettingsStore, store: UsageStore) -> SpendDashboardConfiguration {
        let providers = self.costCapableProviders(store: store)
        let codexRequests = providers.contains(.codex)
            ? self.codexRequests(settings: settings, store: store)
            : []
        return self.configuration(
            settings: settings,
            store: store,
            providers: providers,
            codexRequests: codexRequests)
    }

    @MainActor
    private static func configuration(
        settings: SettingsStore,
        store: UsageStore,
        providers: [UsageProvider],
        codexRequests: [CodexSpendScanRequest]) -> SpendDashboardConfiguration
    {
        SpendDashboardConfiguration(
            costUsageEnabled: settings.costUsageEnabled,
            preferredCurrencyCode: settings.preferredCurrencyCode,
            providerIDs: Array(Set(
                (providers + self.localModelHistoryProviders(store: store)).map(\.rawValue))).sorted(),
            codexAccountIdentities: codexRequests.map { "\($0.id)|\($0.cacheIdentity)" },
            codexAccountDisplayNames: self.codexDisplayNamesByID(codexRequests),
            sourceOwnershipFingerprints: self.sourceOwnershipFingerprints(
                providers: providers,
                settings: settings,
                store: store),
            sourceRevisions: self.sourceRevisions(providers: providers, settings: settings, store: store))
    }

    @MainActor
    static func makeRequest(
        settings: SettingsStore,
        store: UsageStore,
        mode: SpendDashboardRequestBuildMode,
        now: Date? = nil,
        nowProvider: @escaping @Sendable () -> Date = { Date() }) async -> SpendDashboardLoadRequest
    {
        guard settings.costUsageEnabled else {
            return SpendDashboardLoadRequest(
                configuration: self.configuration(settings: settings, store: store),
                capturedInputs: [],
                unavailableSourceIDs: [],
                codexRequests: [],
                now: now ?? nowProvider(),
                force: mode.forcesLoader)
        }

        let initialProviders = self.costCapableProviders(store: store)
        let providerBaselines = initialProviders.filter { $0 != .codex }.map { provider in
            (
                provider: provider,
                publication: store.tokenSnapshotPublicationForCurrentProviderConfig(for: provider),
                publicationRevision: store.tokenSnapshotPublicationRevision(for: provider))
        }
        for baseline in providerBaselines where mode.shouldRefresh(hasPublication: baseline.publication != nil) {
            if UsageStore.tokenCostRequiresProviderSnapshot(baseline.provider) {
                await store.refreshProvider(baseline.provider)
            } else {
                await store.refreshTokenUsageNow(for: baseline.provider, force: true)
            }
        }

        // A later provider refresh can suspend while an earlier provider publishes again.
        // Capture every provider only after all refresh work finishes so the request owns the
        // newest same-scope publication available at this boundary.
        let captureNow = now ?? nowProvider()
        let providers = self.costCapableProviders(store: store)
        let codexRequests = providers.contains(.codex)
            ? self.codexRequests(settings: settings, store: store)
            : []
        let configuration = self.configuration(
            settings: settings,
            store: store,
            providers: providers,
            codexRequests: codexRequests)
        guard configuration.costUsageEnabled else {
            return SpendDashboardLoadRequest(
                configuration: configuration,
                capturedInputs: [],
                unavailableSourceIDs: [],
                codexRequests: [],
                now: captureNow,
                force: mode.forcesLoader)
        }

        var inputs: [SpendDashboardModel.ProviderInput] = []
        var unavailableSourceIDs: Set<String> = []
        var confirmedEmptySourceIDs: Set<String> = []
        for provider in providers where provider != .codex {
            guard let baseline = providerBaselines.first(where: { $0.provider == provider }) else {
                unavailableSourceIDs.insert(provider.rawValue)
                continue
            }
            let shouldRefresh = mode.shouldRefresh(hasPublication: baseline.publication != nil)
            let current = store.tokenSnapshotPublicationForCurrentProviderConfig(for: provider)
            guard let current else {
                unavailableSourceIDs.insert(provider.rawValue)
                continue
            }
            if shouldRefresh, baseline.publicationRevision == current.publicationRevision {
                unavailableSourceIDs.insert(provider.rawValue)
                continue
            }
            guard let snapshot = current.snapshot else {
                confirmedEmptySourceIDs.insert(provider.rawValue)
                continue
            }
            inputs.append(SpendDashboardModel.ProviderInput(
                provider: provider,
                displayName: store.metadata(for: provider).displayName,
                subscriptionName: SpendSubscriptionPlan
                    .from(snapshot: store.snapshot(for: provider), provider: provider)?
                    .displayName,
                snapshot: snapshot))
        }
        return SpendDashboardLoadRequest(
            configuration: configuration,
            capturedInputs: inputs,
            unavailableSourceIDs: unavailableSourceIDs,
            confirmedEmptySourceIDs: confirmedEmptySourceIDs,
            codexRequests: codexRequests,
            localHistoryRequests: self.localHistoryRequests(store: store),
            now: captureNow,
            force: mode.forcesLoader)
    }

    static func load(_ request: SpendDashboardLoadRequest) async -> SpendDashboardLoadResult {
        await self.load(
            request,
            codexSnapshotLoader: { context in
                try await self.loadCodexSnapshot(context)
            },
            kimiCodeSnapshotLoader: { context in
                try await self.loadKimiCodeSnapshot(context)
            },
            geminiSnapshotLoader: { context in
                try await self.loadGeminiSnapshot(context)
            },
            openCodeSnapshotLoader: { context in
                try await self.loadOpenCodeSnapshot(context)
            },
            miniMaxSnapshotLoader: { context in
                try await self.loadMiniMaxSnapshot(context)
            },
            antigravitySnapshotLoader: { context in
                try await self.loadAntigravitySnapshot(context)
            },
            qwenCodeSnapshotLoader: { context in
                try await self.loadQwenCodeSnapshot(context)
            })
    }

    /// One registered local history adapter. The dashboard does not need to
    /// know the scanner's file format; adding a tool only registers another
    /// adapter and opts the provider descriptor into its stable source ID.
    private struct LocalHistoryAdapter {
        let source: ProviderLocalHistorySource
        let displayName: String
        let load: @Sendable (String, Date, Int) async throws -> CostUsageTokenSnapshot?
    }

    private struct LocalHistoryLoaders {
        let kimiCode: KimiCodeSnapshotLoader
        let gemini: GeminiSnapshotLoader
        let openCode: OpenCodeSnapshotLoader
        let miniMax: MiniMaxSnapshotLoader
        let antigravity: AntigravitySnapshotLoader
        let qwenCode: QwenCodeSnapshotLoader
    }

    /// A local tool whose usage snapshot is loaded from a home directory via a
    /// registered, injectable adapter.
    private struct LocalSnapshotSource {
        let homePath: String?
        let sourceID: String
        let provider: UsageProvider
        let displayName: String
        let load: (String) async throws -> CostUsageTokenSnapshot?

        func loadInput() async throws -> SpendDashboardModel.ProviderInput? {
            guard let homePath else { return nil }
            guard let snapshot = try await self.load(homePath) else { return nil }
            return SpendDashboardModel.ProviderInput(
                id: self.sourceID,
                provider: self.provider,
                displayName: self.displayName,
                modelProviderName: ProviderDescriptorRegistry.descriptor(for: self.provider)
                    .metadata.displayName,
                snapshot: snapshot)
        }
    }

    static func load(
        _ request: SpendDashboardLoadRequest,
        codexSnapshotLoader: CodexSnapshotLoader,
        kimiCodeSnapshotLoader: @escaping KimiCodeSnapshotLoader = { context in
            try await Self.loadKimiCodeSnapshot(context)
        },
        geminiSnapshotLoader: @escaping GeminiSnapshotLoader = { context in
            try await Self.loadGeminiSnapshot(context)
        },
        openCodeSnapshotLoader: @escaping OpenCodeSnapshotLoader = { context in
            try await Self.loadOpenCodeSnapshot(context)
        },
        miniMaxSnapshotLoader: @escaping MiniMaxSnapshotLoader = { context in
            try await Self.loadMiniMaxSnapshot(context)
        },
        antigravitySnapshotLoader: @escaping AntigravitySnapshotLoader = { context in
            try await Self.loadAntigravitySnapshot(context)
        },
        qwenCodeSnapshotLoader: @escaping QwenCodeSnapshotLoader = { context in
            try await Self.loadQwenCodeSnapshot(context)
        }) async -> SpendDashboardLoadResult
    {
        var inputs = request.capturedInputs
        var failedSourceIDs = request.unavailableSourceIDs
        var invalidatedSourceIDs: Set<String> = []
        for account in request.codexRequests {
            let sourceID = "codex:\(account.id)"
            do {
                guard self.currentAuthFingerprint(for: account) == account.authFingerprint else {
                    failedSourceIDs.insert(sourceID)
                    invalidatedSourceIDs.insert(sourceID)
                    continue
                }
                let cacheRoot = UsageStore.costUsageCacheDirectory()
                    .appendingPathComponent("accounts", isDirectory: true)
                    .appendingPathComponent(account.cacheIdentity, isDirectory: true)
                let snapshot = try await codexSnapshotLoader(CodexSpendSnapshotLoadContext(
                    account: account,
                    cacheRoot: cacheRoot,
                    now: request.now,
                    force: request.force,
                    historyDays: Self.scanDays,
                    refreshPricingInBackground: false,
                    includePiSessions: false))
                try Task.checkCancellation()
                guard self.currentAuthFingerprint(for: account) == account.authFingerprint else {
                    failedSourceIDs.insert(sourceID)
                    invalidatedSourceIDs.insert(sourceID)
                    continue
                }
                inputs.append(SpendDashboardModel.ProviderInput(
                    id: sourceID,
                    provider: .codex,
                    displayName: account.displayName,
                    modelProviderName: ProviderDescriptorRegistry.descriptor(for: .codex).metadata.displayName,
                    subscriptionName: nil,
                    snapshot: snapshot))
            } catch is CancellationError {
                failedSourceIDs.formUnion(request.codexRequests.map { "codex:\($0.id)" })
                return SpendDashboardLoadResult(
                    inputs: [],
                    failedSourceIDs: failedSourceIDs,
                    invalidatedSourceIDs: invalidatedSourceIDs)
            } catch {
                failedSourceIDs.insert(sourceID)
            }
        }
        let adapters = self.localHistoryAdapters(loaders: LocalHistoryLoaders(
            kimiCode: kimiCodeSnapshotLoader,
            gemini: geminiSnapshotLoader,
            openCode: openCodeSnapshotLoader,
            miniMax: miniMaxSnapshotLoader,
            antigravity: antigravitySnapshotLoader,
            qwenCode: qwenCodeSnapshotLoader))
        let localSources: [LocalSnapshotSource] = request.localHistoryRequests.compactMap { localRequest in
            guard let adapter = adapters[localRequest.source] else {
                failedSourceIDs.insert(self.localSourceID(for: localRequest))
                return nil
            }
            return LocalSnapshotSource(
                homePath: localRequest.homePath,
                sourceID: self.localSourceID(for: localRequest),
                provider: localRequest.provider,
                displayName: adapter.displayName,
                load: { homePath in
                    try await adapter.load(homePath, request.now, Self.scanDays)
                })
        }
        for source in localSources {
            do {
                if let input = try await source.loadInput() {
                    inputs.append(input)
                    // The spend dashboard's canonical history for these providers is the local
                    // scanner. A failed/unchanged live quota publication must not remain as a
                    // refresh warning after the corresponding local history loaded successfully.
                    failedSourceIDs.remove(source.provider.rawValue)
                }
            } catch is CancellationError {
                failedSourceIDs.insert(source.sourceID)
                return SpendDashboardLoadResult(
                    inputs: [],
                    failedSourceIDs: failedSourceIDs,
                    invalidatedSourceIDs: invalidatedSourceIDs)
            } catch {
                failedSourceIDs.insert(source.sourceID)
            }
        }
        let lateInvalidatedSourceIDs = Set(request.codexRequests.compactMap { account in
            self.currentAuthFingerprint(for: account) == account.authFingerprint
                ? nil
                : "codex:\(account.id)"
        })
        failedSourceIDs.formUnion(lateInvalidatedSourceIDs)
        invalidatedSourceIDs.formUnion(lateInvalidatedSourceIDs)
        inputs.removeAll { lateInvalidatedSourceIDs.contains($0.id) }
        return SpendDashboardLoadResult(
            inputs: inputs,
            failedSourceIDs: failedSourceIDs,
            invalidatedSourceIDs: invalidatedSourceIDs)
    }

    private static func loadCodexSnapshot(
        _ context: CodexSpendSnapshotLoadContext) async throws -> CostUsageTokenSnapshot
    {
        try await CostUsageFetcher(cacheRoot: context.cacheRoot).loadTokenSnapshot(
            provider: .codex,
            environment: CodexHomeScope.scopedEnvironment(base: [:], codexHome: context.account.homePath),
            now: context.now,
            forceRefresh: context.force,
            codexHomePath: context.account.homePath,
            historyDays: context.historyDays,
            refreshPricingInBackground: context.refreshPricingInBackground,
            includePiSessions: context.includePiSessions)
    }

    private static func loadKimiCodeSnapshot(
        _ context: KimiCodeSpendSnapshotLoadContext) async throws -> CostUsageTokenSnapshot?
    {
        try await CostUsageScanExecutor.run { checkCancellation in
            try KimiCodeSessionScanner.scanCancellable(
                environment: [KimiSettingsReader.codeHomeEnvironmentKey: context.homePath],
                historyDays: context.historyDays,
                now: context.now,
                checkCancellation: checkCancellation)
        }
    }

    private static func loadGeminiSnapshot(
        _ context: GeminiSpendSnapshotLoadContext) async throws -> CostUsageTokenSnapshot?
    {
        try await CostUsageScanExecutor.run { checkCancellation in
            try GeminiSessionScanner.scanCancellable(
                environment: [GeminiSessionScanner.cliHomeEnvironmentKey: context.homePath],
                historyDays: context.historyDays,
                now: context.now,
                checkCancellation: checkCancellation)
        }
    }

    private static func loadOpenCodeSnapshot(
        _ context: OpenCodeSpendSnapshotLoadContext) async throws -> CostUsageTokenSnapshot?
    {
        try await CostUsageScanExecutor.run { checkCancellation in
            try OpenCodeSessionScanner.scanCancellable(
                environment: [OpenCodeSessionScanner.dataHomeEnvironmentKey: context.homePath],
                historyDays: context.historyDays,
                now: context.now,
                checkCancellation: checkCancellation)
        }
    }

    private static func loadMiniMaxSnapshot(
        _ context: MiniMaxSpendSnapshotLoadContext) async throws -> CostUsageTokenSnapshot?
    {
        try await CostUsageScanExecutor.run { checkCancellation in
            try MiniMaxSessionScanner.scanCancellable(
                environment: [MiniMaxSessionScanner.homeEnvironmentKey: context.homePath],
                historyDays: context.historyDays,
                now: context.now,
                checkCancellation: checkCancellation)
        }
    }

    private static func loadAntigravitySnapshot(
        _ context: AntigravitySpendSnapshotLoadContext) async throws -> CostUsageTokenSnapshot?
    {
        try await CostUsageScanExecutor.run { checkCancellation in
            try AntigravitySessionScanner.scanCancellable(
                environment: [AntigravitySessionScanner.homeEnvironmentKey: context.homePath],
                historyDays: context.historyDays,
                now: context.now,
                checkCancellation: checkCancellation)
        }
    }

    private static func loadQwenCodeSnapshot(
        _ context: QwenCodeSpendSnapshotLoadContext) async throws -> CostUsageTokenSnapshot?
    {
        try await CostUsageScanExecutor.run { checkCancellation in
            try QwenCodeSessionScanner.scanCancellable(
                environment: [QwenCodeSessionScanner.homeEnvironmentKey: context.homePath],
                historyDays: context.historyDays,
                now: context.now,
                checkCancellation: checkCancellation)
        }
    }

    private static func localHistoryAdapters(loaders: LocalHistoryLoaders)
        -> [ProviderLocalHistorySource: LocalHistoryAdapter]
    {
        let adapters = [
            LocalHistoryAdapter(source: .kimiCode, displayName: "Kimi Code CLI") { homePath, now, days in
                try await loaders.kimiCode(KimiCodeSpendSnapshotLoadContext(
                    homePath: homePath, now: now, historyDays: days))
            },
            LocalHistoryAdapter(source: .geminiCLI, displayName: "Gemini CLI") { homePath, now, days in
                try await loaders.gemini(GeminiSpendSnapshotLoadContext(
                    homePath: homePath, now: now, historyDays: days))
            },
            LocalHistoryAdapter(source: .openCode, displayName: "OpenCode") { homePath, now, days in
                try await loaders.openCode(OpenCodeSpendSnapshotLoadContext(
                    homePath: homePath, now: now, historyDays: days))
            },
            LocalHistoryAdapter(source: .miniMax, displayName: "MiniMax Code") { homePath, now, days in
                try await loaders.miniMax(MiniMaxSpendSnapshotLoadContext(
                    homePath: homePath, now: now, historyDays: days))
            },
            LocalHistoryAdapter(source: .antigravity, displayName: "Antigravity") { homePath, now, days in
                try await loaders.antigravity(AntigravitySpendSnapshotLoadContext(
                    homePath: homePath, now: now, historyDays: days))
            },
            LocalHistoryAdapter(source: .qwenCode, displayName: "Qwen Code CLI") { homePath, now, days in
                try await loaders.qwenCode(QwenCodeSpendSnapshotLoadContext(
                    homePath: homePath, now: now, historyDays: days))
            },
            // New registry-era sources. These call the scanner directly (no separate injectable
            // loader) because their coverage lives in the Core scanner suites; the dashboard only
            // needs the home path threaded through.
            LocalHistoryAdapter(source: .zcode, displayName: "ZCode") { homePath, now, days in
                try await CostUsageScanExecutor.run { checkCancellation in
                    try ZcodeSessionScanner.scanCancellable(
                        environment: [ZcodeSessionScanner.homeEnvironmentKey: homePath],
                        historyDays: days,
                        now: now,
                        checkCancellation: checkCancellation)
                }
            },
            LocalHistoryAdapter(source: .copilot, displayName: "GitHub Copilot") { homePath, now, days in
                try await CostUsageScanExecutor.run { checkCancellation in
                    try CopilotSessionScanner.scanCancellable(
                        environment: [CopilotSessionScanner.homeEnvironmentKey: homePath],
                        historyDays: days,
                        now: now,
                        checkCancellation: checkCancellation)
                }
            },
            LocalHistoryAdapter(source: .cursorLocal, displayName: "Cursor") { homePath, now, days in
                try await CostUsageScanExecutor.run { checkCancellation in
                    try CursorLocalActivityScanner.scanCancellable(
                        environment: [CursorLocalActivityScanner.homeEnvironmentKey: homePath],
                        historyDays: days,
                        now: now,
                        checkCancellation: checkCancellation)
                }
            },
        ]
        return Dictionary(uniqueKeysWithValues: adapters.map { ($0.source, $0) })
    }

    private static func localSourceID(for request: LocalSpendHistoryRequest) -> String {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: request.provider)
        if descriptor.tokenCost.localHistorySources.count == 1 {
            return "\(request.provider.rawValue):local"
        }
        return "\(request.provider.rawValue):local:\(request.source.rawValue)"
    }

    /// Main-actor capture of the Gemini CLI home, mirroring `KimiSettingsReader.kimiCodeHomeURL`
    /// (the scanner itself appends `tmp` to whatever `GEMINI_CLI_HOME` resolves to).
    private static func geminiCLIHomeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let override = environment[GeminiSessionScanner.cliHomeEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
    }

    /// Main-actor capture of the XDG data home feeding `OpenCodeSessionScanner` (the scanner
    /// itself appends `opencode/storage/message` to whatever `XDG_DATA_HOME` resolves to).
    private static func openCodeDataHomeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let override = environment[OpenCodeSessionScanner.dataHomeEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
    }

    /// Main-actor capture of the MiniMax home feeding `MiniMaxSessionScanner` (the scanner itself
    /// appends `v2/sqlite/runtime-state.sqlite` to whatever `MINIMAX_HOME` resolves to).
    private static func miniMaxHomeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let override = environment[MiniMaxSessionScanner.homeEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".minimax", isDirectory: true)
    }

    /// Main-actor capture of the Antigravity home feeding `AntigravitySessionScanner` (the scanner
    /// itself appends `conversations` to whatever `ANTIGRAVITY_HOME` resolves to).
    private static func antigravityHomeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let override = environment[AntigravitySessionScanner.homeEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity", isDirectory: true)
    }

    /// Main-actor capture of the Cursor home feeding `CursorLocalActivityScanner` (the scanner
    /// appends `ai-tracking/ai-code-tracking.db` to whatever `CURSOR_HOME` resolves to).
    private static func cursorLocalHomeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let override = environment[CursorLocalActivityScanner.homeEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor", isDirectory: true)
    }

    @MainActor
    static func costCapableProviders(store: UsageStore) -> [UsageProvider] {
        store.enabledProvidersForDisplay().filter {
            ProviderDescriptorRegistry.descriptor(for: $0).tokenCost.supportsTokenCost
        }
    }

    @MainActor
    static func localModelHistoryProviders(store: UsageStore) -> [UsageProvider] {
        store.enabledProvidersForDisplay().filter {
            !ProviderDescriptorRegistry.descriptor(for: $0).tokenCost.localHistorySources.isEmpty
        }
    }

    @MainActor
    static func localHistoryRequests(store: UsageStore) -> [LocalSpendHistoryRequest] {
        self.localModelHistoryProviders(store: store).flatMap { provider in
            ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.localHistorySources.map { source in
                LocalSpendHistoryRequest(
                    source: source,
                    provider: provider,
                    homePath: self.localHistoryHomeURL(for: source).path)
            }
        }
    }

    private static func localHistoryHomeURL(
        for source: ProviderLocalHistorySource,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        let resolvers: [ProviderLocalHistorySource: ([String: String]) -> URL] = [
            .kimiCode: { KimiSettingsReader.kimiCodeHomeURL(environment: $0) },
            .geminiCLI: { self.geminiCLIHomeURL(environment: $0) },
            .openCode: { self.openCodeDataHomeURL(environment: $0) },
            .miniMax: { self.miniMaxHomeURL(environment: $0) },
            .antigravity: { self.antigravityHomeURL(environment: $0) },
            .qwenCode: { QwenCodeSessionScanner.homeURL(environment: $0) },
            .zcode: { ZcodeSessionScanner.homeURL(environment: $0) },
            .copilot: { CopilotSessionScanner.homeURL(environment: $0) },
            .cursorLocal: { self.cursorLocalHomeURL(environment: $0) },
        ]
        // Unknown adapter identifiers cannot be scanned until their plugin
        // registers a resolver. Returning an impossible path keeps request
        // construction deterministic; loading reports the source as failed.
        return resolvers[source]?(environment)
            ?? URL(fileURLWithPath: "/.codexbar/unknown-local-history-source", isDirectory: true)
    }

    @MainActor
    static func codexRequests(settings: SettingsStore, store: UsageStore) -> [CodexSpendScanRequest] {
        let accounts = settings.codexVisibleAccountProjection.visibleAccounts
        let providerName = store.metadata(for: .codex).displayName
        return accounts.enumerated().compactMap { index, account in
            let homePath: String? = switch account.selectionSource {
            case .liveSystem:
                settings.liveSystemCodexHomePath(forActiveSource: .liveSystem)
            case let .managedAccount(id):
                settings.managedCodexRemoteHomePath(forActiveSource: .managedAccount(id: id))
            case let .profileHome(path):
                settings.profileCodexHomePath(forActiveSource: .profileHome(path: path))
            }
            return self.codexRequest(
                account: account,
                homePath: homePath,
                providerName: providerName,
                index: index,
                count: accounts.count)
        }
    }

    @MainActor
    private static func sourceRevisions(
        providers: [UsageProvider],
        settings: SettingsStore,
        store: UsageStore) -> [String]
    {
        ["settings:\(settings.configRevision)"] + providers.compactMap { provider in
            guard provider != .codex else { return nil }
            let current = store.tokenSnapshotPublicationForCurrentProviderConfig(for: provider)
            guard let current else { return "\(provider.rawValue):unavailable" }
            guard let snapshot = current.snapshot else {
                return "\(provider.rawValue):empty:\(current.publicationRevision)"
            }
            return "\(provider.rawValue):snapshot:\(current.publicationRevision):\(self.snapshotRevision(snapshot))"
        }
    }

    private static func snapshotRevision(_ snapshot: CostUsageTokenSnapshot) -> String {
        var encoder = SpendDashboardSnapshotRevisionEncoder()
        encoder.append(snapshot.currencyCode)
        encoder.append(snapshot.historyDays)
        encoder.append(snapshot.historyCoverageIsEstablished)
        encoder.append(snapshot.updatedAt.timeIntervalSinceReferenceDate)
        encoder.append(snapshot.last30DaysTokens)
        encoder.append(snapshot.last30DaysCostUSD)
        encoder.append(snapshot.daily.count)
        for entry in snapshot.daily {
            encoder.append(entry.date)
            encoder.append(entry.inputTokens)
            encoder.append(entry.cacheReadTokens)
            encoder.append(entry.cacheCreationTokens)
            encoder.append(entry.outputTokens)
            encoder.append(entry.totalTokens)
            encoder.append(entry.requestCount)
            encoder.append(entry.costUSD)
            encoder.append(entry.modelBreakdowns?.count)
            for breakdown in entry.modelBreakdowns ?? [] {
                encoder.append(breakdown.modelName)
                encoder.append(breakdown.totalTokens)
                encoder.append(breakdown.requestCount)
                encoder.append(breakdown.costUSD)
                encoder.append(breakdown.standardCostUSD)
                encoder.append(breakdown.priorityCostUSD)
                encoder.append(breakdown.standardTokens)
                encoder.append(breakdown.priorityTokens)
            }
        }
        return encoder.finalize()
    }

    @MainActor
    private static func sourceOwnershipFingerprints(
        providers: [UsageProvider],
        settings: SettingsStore,
        store: UsageStore) -> [String]
    {
        providers.compactMap { provider in
            guard provider != .codex else { return nil }
            var config = settings.providerConfig(for: provider) ?? ProviderConfig(id: provider)
            config.enabled = nil
            config.quotaWarnings = nil
            // The dashboard follows the effective account, not the whole saved-account collection.
            // Inactive-account edits must not invalidate visible spend for the selected account.
            config.tokenAccounts = nil
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = (try? encoder.encode(config)) ?? Data()
            let scope = store.tokenSnapshotScopeSignature(for: provider)
            let accountOwnership = settings.effectiveSelectedTokenAccount(for: provider)
                .map { store.tokenAccountSnapshotCacheKey(provider: provider, account: $0) }
                ?? "ambient"
            return "\(provider.rawValue):\(self.sha256(encoded)):\(self.sha256(scope)):" +
                self.sha256(accountOwnership)
        }
    }

    static func codexRequest(
        account: CodexVisibleAccount,
        homePath: String?,
        providerName: String,
        index: Int,
        count: Int) -> CodexSpendScanRequest?
    {
        guard let homePath = CodexHomeScope.normalizedHomePath(homePath) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: homePath, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: homePath)
        else { return nil }
        let sourceToken = self.sourceToken(account.selectionSource)
        let liveAuthFingerprint = CodexAuthFingerprint.fingerprint(homePath: homePath)
        let authFingerprint = liveAuthFingerprint
            ?? CodexAuthFingerprint.normalize(account.authFingerprint)
        let cacheIdentity = self.sha256([
            account.id,
            sourceToken,
            homePath,
            authFingerprint ?? "missing-auth",
        ].joined(separator: "\u{0}"))
        let displayName = count == 1
            ? providerName
            : "\(providerName) · #\(codexBarLocalizedInteger(index + 1))"
        return CodexSpendScanRequest(
            id: account.id,
            displayName: displayName,
            source: account.selectionSource,
            homePath: homePath,
            authFingerprint: authFingerprint,
            authFileWasReadable: liveAuthFingerprint != nil,
            cacheIdentity: cacheIdentity)
    }

    private static func codexDisplayNamesByID(_ requests: [CodexSpendScanRequest]) -> [String: String] {
        requests.reduce(into: [:]) { result, request in
            result["codex:\(request.id)"] = request.displayName
        }
    }

    private static func sourceToken(_ source: CodexActiveSource) -> String {
        switch source {
        case .liveSystem: "live"
        case let .managedAccount(id): "managed:\(id.uuidString.lowercased())"
        case let .profileHome(path): "profile:\(path)"
        }
    }

    private static func sha256(_ value: String) -> String {
        self.sha256(Data(value.utf8))
    }

    private static func sha256(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }

    private static func currentAuthFingerprint(for request: CodexSpendScanRequest) -> String? {
        let current = CodexAuthFingerprint.fingerprint(homePath: request.homePath)
        return request.authFileWasReadable ? current : current ?? request.authFingerprint
    }
}

private struct SpendDashboardSnapshotRevisionEncoder {
    private var hasher = SHA256()

    mutating func append(_ value: String) {
        let data = Data(value.utf8)
        self.append(UInt64(data.count))
        self.hasher.update(data: data)
    }

    mutating func append(_ value: Int) {
        self.append(UInt64(bitPattern: Int64(value)))
    }

    mutating func append(_ value: Int?) {
        guard let value else {
            self.appendPresence(false)
            return
        }
        self.appendPresence(true)
        self.append(value)
    }

    mutating func append(_ value: Bool) {
        self.appendPresence(value)
    }

    mutating func append(_ value: Double) {
        self.append(value.bitPattern)
    }

    mutating func append(_ value: Double?) {
        guard let value else {
            self.appendPresence(false)
            return
        }
        self.appendPresence(true)
        self.append(value)
    }

    mutating func finalize() -> String {
        self.hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private mutating func appendPresence(_ isPresent: Bool) {
        var byte: UInt8 = isPresent ? 1 : 0
        withUnsafeBytes(of: &byte) { bytes in
            self.hasher.update(data: Data(bytes))
        }
    }

    private mutating func append(_ value: UInt64) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { bytes in
            self.hasher.update(data: Data(bytes))
        }
    }
}

@MainActor
@Observable
final class SpendDashboardController {
    typealias RequestBuilder = @MainActor @Sendable (SpendDashboardRequestBuildMode) async
        -> SpendDashboardLoadRequest
    typealias Loader = @Sendable (SpendDashboardLoadRequest) async -> SpendDashboardLoadResult

    private enum ReconciliationObservation: Sendable {
        case confirmedEmpty
        case confirmedNonempty(SpendDashboardModel.ProviderInput)
    }

    private struct ForcedOutcome: Sendable {
        let request: SpendDashboardLoadRequest
        let result: SpendDashboardLoadResult
        let invalidatedSourceIDs: Set<String>
        let observations: [String: ReconciliationObservation]

        func incorporating(capture: SpendDashboardLoadRequest) -> Self {
            var observations = self.observations
            for input in capture.capturedInputs {
                let forcedRevision = Self.sourceRevision(for: input.id, in: self.request.configuration)
                let captureRevision = Self.sourceRevision(for: input.id, in: capture.configuration)
                let hasNewerSourceRevision = forcedRevision != nil
                    && captureRevision != nil
                    && forcedRevision != captureRevision
                if self.result.failedSourceIDs.contains(input.id),
                   observations[input.id] == nil,
                   !hasNewerSourceRevision
                {
                    continue
                }
                observations[input.id] = .confirmedNonempty(input)
            }
            for sourceID in capture.confirmedEmptySourceIDs {
                observations[sourceID] = .confirmedEmpty
            }
            return Self(
                request: self.request,
                result: self.result,
                invalidatedSourceIDs: self.invalidatedSourceIDs,
                observations: observations)
        }

        private static func sourceRevision(
            for sourceID: String,
            in configuration: SpendDashboardConfiguration) -> String?
        {
            let prefix = "\(sourceID):"
            return configuration.sourceRevisions.first { $0.hasPrefix(prefix) }
        }

        var confirmedEmptySourceIDs: Set<String> {
            Set(self.observations.compactMap { sourceID, observation in
                guard case .confirmedEmpty = observation else { return nil }
                return sourceID
            })
        }

        var confirmedNonemptyInputs: [SpendDashboardModel.ProviderInput] {
            self.observations.sorted { $0.key < $1.key }.compactMap { _, observation in
                guard case let .confirmedNonempty(input) = observation else { return nil }
                return input
            }
        }
    }

    private struct ReconciledOutcome: Sendable {
        let result: SpendDashboardLoadResult
        let confirmedEmptySourceIDs: Set<String>
    }

    private enum LoadPhase: Sendable {
        case ordinary
        case forcing
        case reconciling(ForcedOutcome)

        var buildMode: SpendDashboardRequestBuildMode {
            switch self {
            case .ordinary: .refreshMissing
            case .forcing: .forceRefresh
            case .reconciling: .captureOnly
            }
        }

        var manualRefreshOutstanding: Bool {
            switch self {
            case .ordinary: false
            case .forcing, .reconciling: true
            }
        }
    }

    private(set) var model = SpendDashboardModel(requestedDays: 30, groups: [])
    private(set) var isRefreshing = false
    private(set) var failedSourceCount = 0
    private(set) var failedSourceIDs: Set<String> = []
    private(set) var generation: UInt64 = 0
    private(set) var configuration: SpendDashboardConfiguration?
    private(set) var selectedDays: Int

    private static let daysDefaultsKey = "settingsSpendDashboardDays"
    private let userDefaults: UserDefaults
    private let requestBuilder: RequestBuilder
    private let loader: Loader
    private let nowProvider: @Sendable () -> Date
    private var loadTask: Task<Void, Never>?
    private var loadedInputs: [SpendDashboardModel.ProviderInput] = []
    private var loadedAt = Date()
    private var lastCompletedLoadAt: Date?
    private var lastSuccessfulConfiguration: SpendDashboardConfiguration?
    private var phase = LoadPhase.ordinary

    init(
        userDefaults: UserDefaults = .standard,
        requestBuilder: @escaping RequestBuilder,
        loader: @escaping Loader = SpendDashboardSource.load,
        nowProvider: @escaping @Sendable () -> Date = { Date() })
    {
        self.userDefaults = userDefaults
        self.requestBuilder = requestBuilder
        self.loader = loader
        self.nowProvider = nowProvider
        self.selectedDays = Self.normalizedDays(userDefaults.integer(forKey: Self.daysDefaultsKey))
    }

    func update(configuration: SpendDashboardConfiguration, force: Bool = false) {
        self.refreshRetainedCodexDisplayNames(configuration.codexAccountDisplayNames)
        if force {
            self.configuration = configuration
            self.startLoad(configuration: configuration, phase: .forcing)
            return
        }
        guard configuration != self.configuration else { return }
        let previousConfiguration = self.configuration
        self.configuration = configuration
        if self.phase.manualRefreshOutstanding,
           let previousConfiguration,
           Self.sameSourceOwnership(previousConfiguration, configuration)
        {
            return
        }
        let nextPhase: LoadPhase = self.phase.manualRefreshOutstanding ? .forcing : .ordinary
        self.startLoad(configuration: configuration, phase: nextPhase)
    }

    private func startLoad(
        configuration: SpendDashboardConfiguration,
        phase: LoadPhase)
    {
        self.generation &+= 1
        let generation = self.generation
        self.loadTask?.cancel()
        let invalidatedSourceIDs = switch phase {
        case let .reconciling(outcome): outcome.invalidatedSourceIDs
        case .ordinary, .forcing:
            Self.invalidatedSourceIDs(
                previous: self.lastSuccessfulConfiguration,
                current: configuration)
        }
        self.phase = phase

        if !invalidatedSourceIDs.isEmpty {
            self.loadedInputs.removeAll { invalidatedSourceIDs.contains($0.id) }
            self.failedSourceCount = 0
            self.failedSourceIDs = []
            self.rebuildModel()
        }

        guard configuration.costUsageEnabled, !configuration.providerIDs.isEmpty else {
            self.loadedInputs = []
            self.failedSourceCount = 0
            self.failedSourceIDs = []
            self.isRefreshing = false
            self.lastSuccessfulConfiguration = configuration
            self.phase = .ordinary
            self.loadTask = nil
            self.rebuildModel()
            return
        }

        self.isRefreshing = true
        self.loadTask = Task { [weak self] in
            guard let self else { return }
            let request = await self.requestBuilder(phase.buildMode)
            guard !Task.isCancelled,
                  generation == self.generation
            else { return }
            await self.handleBuiltRequest(
                request,
                startedWith: configuration,
                phase: phase,
                generation: generation,
                invalidatedSourceIDs: invalidatedSourceIDs)
        }
    }

    private func handleBuiltRequest(
        _ request: SpendDashboardLoadRequest,
        startedWith startConfiguration: SpendDashboardConfiguration,
        phase: LoadPhase,
        generation: UInt64,
        invalidatedSourceIDs: Set<String>) async
    {
        guard let targetConfiguration = self.configuration else { return }
        if case let .reconciling(outcome) = phase,
           !Self.sameSourceOwnership(outcome.request.configuration, targetConfiguration)
        {
            self.startLoad(configuration: targetConfiguration, phase: .forcing)
            return
        }
        guard Self.sameSourceOwnership(startConfiguration, targetConfiguration) else {
            self.restartAfterBuildMismatch(targetConfiguration, phase: phase)
            return
        }

        let phase: LoadPhase = if case let .reconciling(outcome) = phase,
                                  Self.sameSourceOwnership(request.configuration, targetConfiguration)
        {
            .reconciling(outcome.incorporating(capture: request))
        } else {
            phase
        }

        if request.configuration != targetConfiguration {
            if case .forcing = phase,
               Self.sameSourceOwnership(request.configuration, targetConfiguration)
            {
                // Same-owner revision churn does not justify another provider force. The forced
                // loader executes once; its mandatory capture barrier reconciles the latest token.
                if targetConfiguration == startConfiguration {
                    self.configuration = request.configuration
                }
            } else if targetConfiguration == startConfiguration,
                      Self.sameSourceOwnership(targetConfiguration, request.configuration)
            {
                // The request owns an atomic newer same-owner capture. Adopt it even when the
                // external observation callback has not delivered that revision yet.
                self.configuration = request.configuration
            } else {
                let nextConfiguration = targetConfiguration == startConfiguration
                    ? request.configuration
                    : targetConfiguration
                self.restartAfterBuildMismatch(nextConfiguration, phase: phase)
                return
            }
        }

        switch phase {
        case .ordinary:
            let result = await self.loader(request)
            guard !Task.isCancelled,
                  generation == self.generation,
                  let latestConfiguration = self.configuration
            else { return }
            guard request.configuration == latestConfiguration else {
                self.startLoad(configuration: latestConfiguration, phase: .ordinary)
                return
            }
            self.apply(
                request: request,
                result: result,
                invalidatedSourceIDs: invalidatedSourceIDs,
                confirmedEmptySourceIDs: request.confirmedEmptySourceIDs)

        case .forcing:
            let result = await self.loader(request)
            guard !Task.isCancelled,
                  generation == self.generation,
                  let latestConfiguration = self.configuration
            else { return }
            guard Self.sameSourceOwnership(request.configuration, latestConfiguration) else {
                self.startLoad(configuration: latestConfiguration, phase: .forcing)
                return
            }
            let outcome = ForcedOutcome(
                request: request,
                result: result,
                invalidatedSourceIDs: invalidatedSourceIDs,
                observations: Dictionary(uniqueKeysWithValues: request.confirmedEmptySourceIDs.map {
                    ($0, ReconciliationObservation.confirmedEmpty)
                }))
            self.startLoad(configuration: latestConfiguration, phase: .reconciling(outcome))

        case let .reconciling(outcome):
            let reconciled = Self.merge(outcome: outcome, capture: request)
            self.apply(
                request: request,
                result: reconciled.result,
                invalidatedSourceIDs: outcome.invalidatedSourceIDs,
                confirmedEmptySourceIDs: reconciled.confirmedEmptySourceIDs)
        }
    }

    private func restartAfterBuildMismatch(
        _ configuration: SpendDashboardConfiguration,
        phase: LoadPhase)
    {
        self.configuration = configuration
        let nextPhase: LoadPhase = switch phase {
        case .ordinary: .ordinary
        case .forcing: .forcing
        case let .reconciling(outcome):
            Self.sameSourceOwnership(outcome.request.configuration, configuration)
                ? .reconciling(outcome)
                : .forcing
        }
        self.startLoad(configuration: configuration, phase: nextPhase)
    }

    private func apply(
        request: SpendDashboardLoadRequest,
        result: SpendDashboardLoadResult,
        invalidatedSourceIDs: Set<String>,
        confirmedEmptySourceIDs: Set<String>)
    {
        let codexDisplayNames = request.configuration.codexAccountDisplayNames
        self.refreshRetainedCodexDisplayNames(codexDisplayNames)
        var nextInputs = result.inputs
        if !result.failedSourceIDs.isEmpty {
            let freshIDs = Set(nextInputs.map(\.id))
            let unsafeSourceIDs = invalidatedSourceIDs
                .union(result.invalidatedSourceIDs)
                .union(confirmedEmptySourceIDs)
            nextInputs.append(contentsOf: self.loadedInputs.filter {
                result.failedSourceIDs.contains($0.id) &&
                    !unsafeSourceIDs.contains($0.id) &&
                    !freshIDs.contains($0.id)
            }.map { Self.relabelCodexInput($0, displayNamesByID: codexDisplayNames) })
        }
        self.configuration = request.configuration
        self.loadedInputs = nextInputs
        self.loadedAt = request.now
        self.lastCompletedLoadAt = self.nowProvider()
        self.lastSuccessfulConfiguration = request.configuration
        self.failedSourceCount = result.failedSourceCount
        self.failedSourceIDs = result.failedSourceIDs
        self.isRefreshing = false
        self.phase = .ordinary
        self.loadTask = nil
        self.rebuildModel()
    }

    private static func merge(
        outcome: ForcedOutcome,
        capture: SpendDashboardLoadRequest) -> ReconciledOutcome
    {
        let forceFailed = outcome.result.failedSourceIDs
        let invalidated = outcome.result.invalidatedSourceIDs
        let barrierFailed = capture.unavailableSourceIDs
        let forcedCodexIDs = Set(outcome.request.codexRequests.map { "codex:\($0.id)" })
        let confirmedNonemptyInputs = outcome.confirmedNonemptyInputs
        let confirmedNonemptyIDs = Set(confirmedNonemptyInputs.map(\.id))
        var inputs = capture.capturedInputs.filter {
            (!forceFailed.contains($0.id) || confirmedNonemptyIDs.contains($0.id)) &&
                !invalidated.contains($0.id) &&
                !outcome.confirmedEmptySourceIDs.contains($0.id)
        }
        var capturedIDs = Set(inputs.map(\.id))
        for input in confirmedNonemptyInputs
            where !capturedIDs.contains(input.id) && !invalidated.contains(input.id)
        {
            inputs.append(input)
            capturedIDs.insert(input.id)
        }
        for input in outcome.result.inputs
            where !capturedIDs.contains(input.id) &&
            !forceFailed.contains(input.id) &&
            !invalidated.contains(input.id) &&
            !outcome.confirmedEmptySourceIDs.contains(input.id) &&
            (forcedCodexIDs.contains(input.id) ||
                barrierFailed.contains(input.id) ||
                Self.isLocalHistorySource(input.id))
        {
            inputs.append(input)
            capturedIDs.insert(input.id)
        }
        return ReconciledOutcome(
            result: SpendDashboardLoadResult(
                inputs: inputs,
                failedSourceIDs: forceFailed.union(barrierFailed),
                invalidatedSourceIDs: invalidated),
            confirmedEmptySourceIDs: outcome.confirmedEmptySourceIDs)
    }

    private static func isLocalHistorySource(_ sourceID: String) -> Bool {
        sourceID.hasSuffix(":local") || sourceID.contains(":local:")
    }

    func refresh() {
        guard let configuration else { return }
        self.update(configuration: configuration, force: true)
    }

    func selectDays(_ days: Int) {
        let days = Self.normalizedDays(days)
        guard days != self.selectedDays else { return }
        self.selectedDays = days
        self.userDefaults.set(days, forKey: Self.daysDefaultsKey)
        self.rebuildModel()
    }

    func refreshDateWindow(
        now: Date? = nil,
        reloadIfOlderThan minimumReloadInterval: TimeInterval? = 0)
    {
        let now = now ?? self.nowProvider()
        self.loadedAt = now
        self.rebuildModel()
        guard let configuration else { return }
        guard let minimumReloadInterval else { return }
        if let lastCompletedLoadAt,
           now.timeIntervalSince(lastCompletedLoadAt) < minimumReloadInterval
        {
            return
        }
        let nextPhase: LoadPhase = self.phase.manualRefreshOutstanding ? .forcing : .ordinary
        self.startLoad(configuration: configuration, phase: nextPhase)
    }

    func stop() {
        self.loadTask?.cancel()
        self.loadTask = nil
        self.configuration = nil
        self.isRefreshing = false
        self.phase = .ordinary
    }

    private func rebuildModel() {
        self.model = SpendDashboardModel.build(
            inputs: self.loadedInputs,
            requestedDays: self.selectedDays,
            now: self.loadedAt,
            preferredCurrencyCode: self.configuration?.preferredCurrencyCode ?? "auto")
    }

    private func refreshRetainedCodexDisplayNames(_ displayNamesByID: [String: String]) {
        guard !displayNamesByID.isEmpty else { return }
        var didChange = false
        let relabeled = self.loadedInputs.map { input in
            let updated = Self.relabelCodexInput(input, displayNamesByID: displayNamesByID)
            didChange = didChange || updated.displayName != input.displayName
            return updated
        }
        guard didChange else { return }
        self.loadedInputs = relabeled
        self.rebuildModel()
    }

    private static func relabelCodexInput(
        _ input: SpendDashboardModel.ProviderInput,
        displayNamesByID: [String: String]) -> SpendDashboardModel.ProviderInput
    {
        guard input.provider == .codex,
              let displayName = displayNamesByID[input.id],
              displayName != input.displayName
        else { return input }
        return SpendDashboardModel.ProviderInput(
            id: input.id,
            provider: input.provider,
            displayName: displayName,
            modelProviderName: input.modelProviderName,
            subscriptionName: input.subscriptionName,
            snapshot: input.snapshot)
    }

    private static func sameSourceOwnership(
        _ lhs: SpendDashboardConfiguration,
        _ rhs: SpendDashboardConfiguration) -> Bool
    {
        lhs.costUsageEnabled == rhs.costUsageEnabled &&
            lhs.providerIDs == rhs.providerIDs &&
            lhs.codexAccountIdentities == rhs.codexAccountIdentities &&
            lhs.sourceOwnershipFingerprints == rhs.sourceOwnershipFingerprints
    }

    private static func invalidatedSourceIDs(
        previous: SpendDashboardConfiguration?,
        current: SpendDashboardConfiguration) -> Set<String>
    {
        guard let previous else { return [] }
        let previousOwnership = self.sourceOwnershipByID(previous.sourceOwnershipFingerprints)
        let currentOwnership = self.sourceOwnershipByID(current.sourceOwnershipFingerprints)
        let providerIDs = Set(previousOwnership.keys).union(currentOwnership.keys)
        let changedProviderIDs = providerIDs.filter { previousOwnership[$0] != currentOwnership[$0] }

        let previousCodexOwnership = self.codexOwnershipByID(previous.codexAccountIdentities)
        let currentCodexOwnership = self.codexOwnershipByID(current.codexAccountIdentities)
        let codexIDs = Set(previousCodexOwnership.keys).union(currentCodexOwnership.keys)
        let changedCodexIDs = codexIDs.filter {
            previousCodexOwnership[$0] != currentCodexOwnership[$0]
        }
        return Set(changedProviderIDs).union(changedCodexIDs)
    }

    private static func sourceOwnershipByID(_ fingerprints: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: fingerprints.compactMap { fingerprint in
            guard let separator = fingerprint.firstIndex(of: ":") else { return nil }
            let sourceID = String(fingerprint[..<separator])
            guard !sourceID.isEmpty else { return nil }
            return (sourceID, fingerprint)
        })
    }

    private static func codexOwnershipByID(_ identities: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: identities.compactMap { identity in
            guard let separator = identity.lastIndex(of: "|") else { return nil }
            let accountID = String(identity[..<separator])
            guard !accountID.isEmpty else { return nil }
            return ("codex:\(accountID)", identity)
        })
    }

    private static func normalizedDays(_ value: Int) -> Int {
        [7, 30, 365].contains(value) ? value : 30
    }
}
