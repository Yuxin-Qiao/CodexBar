#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

public enum CodexOAuthCredentialSource: String, Equatable, Sendable {
    case codexHome
    case legacyCodexHome
    case openCode

    var canPersistRefresh: Bool {
        self == .codexHome
    }
}

public struct CodexOAuthCredentials: Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let idToken: String?
    public let accountId: String?
    public let lastRefresh: Date?
    public let expiresAt: Date?
    public let source: CodexOAuthCredentialSource

    public init(
        accessToken: String,
        refreshToken: String,
        idToken: String?,
        accountId: String?,
        lastRefresh: Date?,
        expiresAt: Date? = nil,
        source: CodexOAuthCredentialSource = .codexHome)
    {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountId = accountId
        self.lastRefresh = lastRefresh
        self.expiresAt = expiresAt
        self.source = source
    }

    public var needsRefresh: Bool {
        if let expiresAt {
            return expiresAt.timeIntervalSinceNow <= 60
        }
        guard let lastRefresh else { return true }
        let eightDays: TimeInterval = 8 * 24 * 60 * 60
        return Date().timeIntervalSince(lastRefresh) > eightDays
    }
}

public enum CodexOAuthCredentialsError: LocalizedError, Sendable {
    case notFound
    case unreadable
    case decodeFailed(String)
    case missingTokens
    case readOnlySource

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "Codex auth.json not found. Run `codex` to log in."
        case .unreadable:
            "Codex auth.json could not be read. Check its permissions or run `codex` to log in again."
        case let .decodeFailed(message):
            "Failed to decode Codex credentials: \(message)"
        case .missingTokens:
            "Codex auth.json exists but contains no tokens."
        case .readOnlySource:
            "This Codex credential source is read-only and cannot be refreshed in place."
        }
    }
}

public enum CodexOAuthCredentialsStore {
    private static func authFilePath(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil) -> URL
    {
        let home = if self.nonEmpty(env["CODEX_HOME"]) != nil {
            CodexHomeScope.ambientHomeURL(env: env, fileManager: fileManager)
        } else {
            (homeDirectory ?? fileManager.homeDirectoryForCurrentUser)
                .appendingPathComponent(".codex", isDirectory: true)
        }
        return home
            .appendingPathComponent("auth.json")
    }

    public static func load(env: [String: String] = ProcessInfo.processInfo
        .environment) throws -> CodexOAuthCredentials
    {
        try self.loadNative(env: env, homeDirectory: nil)
    }

    public static func loadOAuthTokens(env: [String: String] = ProcessInfo.processInfo
        .environment) throws -> CodexOAuthCredentials
    {
        let json = try self.decodeObject(data: self.readAuthData(env: env))
        guard let credentials = self.tokenCredentials(in: json, source: .codexHome) else {
            throw CodexOAuthCredentialsError.missingTokens
        }
        return credentials
    }

    public static func parse(data: Data) throws -> CodexOAuthCredentials {
        try self.parse(data: data, source: .codexHome)
    }

    /// Resolve a credential for a usage probe without changing any source file.
    ///
    /// The ambient Codex home wins. Only an unconfigured ambient home may fall back to
    /// the legacy XDG Codex path or OpenCode's `openai` OAuth entry; an explicit `CODEX_HOME`
    /// remains an isolated scope for managed accounts.
    public static func loadForUsage(env: [String: String] = ProcessInfo.processInfo
        .environment) throws -> CodexOAuthCredentials
    {
        try self.loadForUsage(env: env, homeDirectory: nil)
    }

    private static func loadForUsage(
        env: [String: String],
        homeDirectory: URL?) throws -> CodexOAuthCredentials
    {
        do {
            return try self.loadNative(env: env, homeDirectory: homeDirectory)
        } catch let nativeError as CodexOAuthCredentialsError {
            guard self.shouldTryExternalFallback(nativeError, env: env) else { throw nativeError }
            if let legacy = try? self.loadLegacyCodexCredentials(homeDirectory: homeDirectory) {
                return legacy
            }
            if let openCode = try? self.loadOpenCodeCredentials(env: env, homeDirectory: homeDirectory) {
                return openCode
            }
            throw nativeError
        }
    }

    private static func loadNative(
        env: [String: String],
        homeDirectory: URL?) throws -> CodexOAuthCredentials
    {
        let data = try self.readAuthData(env: env, homeDirectory: homeDirectory)
        return try self.parse(data: data, source: .codexHome)
    }

    private static func parse(
        data: Data,
        source: CodexOAuthCredentialSource) throws -> CodexOAuthCredentials
    {
        let json = try self.decodeObject(data: data)

        if let apiKeyCredentials = Self.apiKeyCredentials(in: json, source: source) {
            return apiKeyCredentials
        }

        if let tokenCredentials = Self.tokenCredentials(in: json, source: source) {
            return tokenCredentials
        }

        throw CodexOAuthCredentialsError.missingTokens
    }

    private static func readAuthData(
        env: [String: String],
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil) throws -> Data
    {
        let url = self.authFilePath(env: env, fileManager: fileManager, homeDirectory: homeDirectory)
        return try self.readAuthData(at: url)
    }

    private static func readAuthData(at url: URL) throws -> Data {
        do {
            // Read once instead of checking existence first. Codex publishes auth.json atomically,
            // so a single read avoids a TOCTOU window and lets us distinguish a missing file from a
            // transiently unreadable/partially published one without logging credentials.
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            let nsError = error as NSError
            let missingFile = (nsError.domain == NSCocoaErrorDomain &&
                nsError.code == CocoaError.fileReadNoSuchFile.rawValue) ||
                (nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT)
            throw missingFile ? CodexOAuthCredentialsError.notFound : CodexOAuthCredentialsError.unreadable
        }
    }

    private static func decodeObject(data: Data) throws -> [String: Any] {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CodexOAuthCredentialsError.decodeFailed("Invalid JSON")
            }
            return json
        } catch let error as CodexOAuthCredentialsError {
            throw error
        } catch {
            throw CodexOAuthCredentialsError.decodeFailed("Invalid JSON")
        }
    }

    private static func tokenCredentials(
        in json: [String: Any],
        source: CodexOAuthCredentialSource) -> CodexOAuthCredentials?
    {
        guard let tokens = json["tokens"] as? [String: Any],
              let accessToken = stringValue(
                  in: tokens,
                  snakeCaseKey: "access_token",
                  camelCaseKey: "accessToken"),
              let refreshToken = stringValue(
                  in: tokens,
                  snakeCaseKey: "refresh_token",
                  camelCaseKey: "refreshToken"),
              !accessToken.isEmpty
        else {
            return nil
        }

        let idToken = Self.stringValue(in: tokens, snakeCaseKey: "id_token", camelCaseKey: "idToken")
        let accountId = Self.stringValue(in: tokens, snakeCaseKey: "account_id", camelCaseKey: "accountId")
        let lastRefresh = Self.parseLastRefresh(from: json["last_refresh"])

        return CodexOAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountId: accountId,
            lastRefresh: lastRefresh,
            source: source)
    }

    private static func apiKeyCredentials(
        in json: [String: Any],
        source: CodexOAuthCredentialSource) -> CodexOAuthCredentials?
    {
        guard let apiKey = json["OPENAI_API_KEY"] as? String,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return CodexOAuthCredentials(
            accessToken: apiKey,
            refreshToken: "",
            idToken: nil,
            accountId: nil,
            lastRefresh: nil,
            source: source)
    }

    public static func save(
        _ credentials: CodexOAuthCredentials,
        env: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        guard credentials.source.canPersistRefresh else {
            throw CodexOAuthCredentialsError.readOnlySource
        }
        let url = self.authFilePath(env: env)

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            json = existing
        }

        var tokens: [String: Any] = [
            "access_token": credentials.accessToken,
            "refresh_token": credentials.refreshToken,
        ]
        if let idToken = credentials.idToken {
            tokens["id_token"] = idToken
        }
        if let accountId = credentials.accountId {
            tokens["account_id"] = accountId
        }

        json["tokens"] = tokens
        json["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try CredentialFileWriter.writePrivate(data, to: url)
    }

    private static func shouldTryExternalFallback(
        _ error: CodexOAuthCredentialsError,
        env: [String: String]) -> Bool
    {
        guard self.nonEmpty(env["CODEX_HOME"]) == nil else { return false }
        switch error {
        case .notFound, .unreadable, .missingTokens:
            return true
        case .decodeFailed, .readOnlySource:
            return false
        }
    }

    private static func loadLegacyCodexCredentials(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil) throws -> CodexOAuthCredentials
    {
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let url = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
            .appendingPathComponent("auth.json")
        return try self.parse(data: self.readAuthData(at: url), source: .legacyCodexHome)
    }

    private static func loadOpenCodeCredentials(
        env: [String: String],
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil) throws -> CodexOAuthCredentials
    {
        let root: URL = if let configured = self.nonEmpty(env["XDG_DATA_HOME"]),
                           let normalized = CodexHomeScope.normalizedHomePath(configured, fileManager: fileManager)
        {
            URL(fileURLWithPath: normalized, isDirectory: true)
        } else {
            (homeDirectory ?? fileManager.homeDirectoryForCurrentUser)
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("share", isDirectory: true)
        }
        // Provider-specific by design: OpenCode stores the OpenAI OAuth entry under its own data directory.
        let url = root
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("auth.json")
        return try self.parseOpenCode(data: self.readAuthData(at: url))
    }

    private static func parseOpenCode(data: Data) throws -> CodexOAuthCredentials {
        let json = try self.decodeObject(data: data)
        guard let auth = json["openai"] as? [String: Any],
              let type = self.nonEmpty(auth["type"] as? String),
              type.caseInsensitiveCompare("oauth") == .orderedSame,
              let access = self.nonEmpty(auth["access"] as? String)
        else {
            throw CodexOAuthCredentialsError.missingTokens
        }
        return CodexOAuthCredentials(
            accessToken: access,
            refreshToken: self.nonEmpty(auth["refresh"] as? String) ?? "",
            idToken: nil,
            accountId: self.nonEmpty(auth["accountId"] as? String),
            lastRefresh: nil,
            expiresAt: self.parseEpochMilliseconds(auth["expires"]),
            source: .openCode)
    }

    private static func parseEpochMilliseconds(_ raw: Any?) -> Date? {
        guard let number = raw as? NSNumber else { return nil }
        let milliseconds = number.doubleValue
        guard milliseconds.isFinite, milliseconds >= 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func parseLastRefresh(from raw: Any?) -> Date? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func stringValue(
        in dictionary: [String: Any],
        snakeCaseKey: String,
        camelCaseKey: String)
        -> String?
    {
        if let value = dictionary[snakeCaseKey] as? String, !value.isEmpty {
            return value
        }
        if let value = dictionary[camelCaseKey] as? String, !value.isEmpty {
            return value
        }
        return nil
    }
}

#if DEBUG
extension CodexOAuthCredentialsStore {
    static func _authFileURLForTesting(env: [String: String]) -> URL {
        self.authFilePath(env: env)
    }

    static func _loadForUsageForTesting(
        env: [String: String],
        homeDirectory: URL) throws -> CodexOAuthCredentials
    {
        try self.loadForUsage(env: env, homeDirectory: homeDirectory)
    }

    static func _parseOpenCodeForTesting(data: Data) throws -> CodexOAuthCredentials {
        try self.parseOpenCode(data: data)
    }

    static func _writePrivateFileForTesting(
        _ data: Data,
        to url: URL,
        beforePublish: @escaping (URL) throws -> Void) throws
    {
        try CredentialFileWriter.writePrivate(data, to: url, beforePublish: beforePublish)
    }
}
#endif
