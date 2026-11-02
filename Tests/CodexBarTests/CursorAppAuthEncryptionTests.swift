import CommonCrypto
import Foundation
import LocalAuthentication
import Security
import SQLite3
import SweetCookieKit
import Testing
@testable import CodexBarCore

@Suite(.serialized, CodexCredentialFixtures())
struct CursorAppAuthEncryptionTests {
    static let password = "synthetic-cursor-safe-storage-password"

    @Test(arguments: ["Cursor Key", "Cursor"])
    func `encrypted app token retains JWT identity expiry and session cookie`(account: String) throws {
        let token = try makeCursorAppAuthToken(subject: "auth0|encrypted-account")
        let session = try Self.withKeychain(accounts: [account]) { try #require(try Self.load(Self.envelope(token))) }
        #expect(session.accessToken == token)
        #expect(session.isUsable)
        #expect(session.identity?.requestUsageUserID == "encrypted-account")
        #expect(try session.cookieHeader() == "WorkosCursorSessionToken=encrypted-account%3A%3A" + token)
    }

    @Test
    func `plain tokens and malformed envelopes never request Safe Storage`() throws {
        let plain = try makeCursorAppAuthToken()
        for token in [
            plain,
            "cursor-safe-storage:v1:" + plain,
            "cursor-safe-storage:v2:" + plain,
            "cursor-safe-storage:v1:!",
            "cursor-safe-storage:v2:AAAA",
            "cursor-safe-storage:v1:" + Data("v10short".utf8).base64EncodedString(),
        ] {
            try Self.withKeychain(preflight: .interactionRequired) { _ in
                Issue.record("A plain token or malformed envelope must not request a secret")
                return (errSecSuccess, nil)
            } operation: {
                try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                    Issue.record("A plain token or malformed envelope must not access Keychain metadata")
                    return .notFound
                } operation: {
                    let session = try #require(try Self.load(token))
                    #expect(session.accessToken == (token == plain ? token : ""))
                    #expect(session.isUsable == (token == plain))
                }
            }
        }
    }

    @Test
    func `raw session cookies preserve cookie-like user IDs`() throws {
        let token = try makeCursorAppAuthToken(subject: "auth0|user-cookie")
        let header = "unrelated=value; WorkosCursorSessionToken=user-cookie::" + token
        #expect(CursorAppAuthSession.from(cookieHeader: header)?.accessToken == token)
        #expect(CursorSessionIdentity.from(cookieHeader: header)?.requestUsageUserID == "user-cookie")
    }

    @Test(arguments: ["Cursor Key", "Cursor"])
    func `decryption preserves expiry and user ID rejection`(account: String) throws {
        for token in try [
            makeCursorAppAuthToken(expiration: Date(timeIntervalSinceNow: -120)),
            makeCursorAppAuthToken(subject: "auth0|invalid;user"),
        ] {
            let session = try Self
                .withKeychain(accounts: [account]) { try #require(try Self.load(Self.envelope(token))) }
            #expect(session.accessToken == token)
            #expect(!session.isUsable)
        }
    }

    @Test(arguments: [[], ["Cursor Key"], ["Cursor"], ["Cursor Key", "Cursor"]])
    func `missing or wrong Safe Storage keys fail closed`(accounts: [String]) throws {
        let envelope = try Self.envelope(makeCursorAppAuthToken())
        let reads = LockIsolated(0)
        let session = try Self.withKeychain(accounts: accounts) { query in
            Self.expectNoUI(query)
            reads.setValue(reads.value + 1)
            return (errSecSuccess, Data("wrong-synthetic-password".utf8))
        } operation: {
            try #require(try Self.load(envelope))
        }
        #expect(reads.value == accounts.count)
        #expect(session.accessToken.isEmpty)
        #expect(!session.isUsable)
    }

    @Test(arguments: [["Cursor Key"], ["Cursor"], ["Cursor Key", "Cursor"]])
    func `background denied no UI read falls through without reviving stale app auth`(accounts: [String]) async throws {
        let envelope = try Self.envelope(makeCursorAppAuthToken())
        let reads = LockIsolated(0)
        let session = try Self.withKeychain(accounts: accounts) { query in
            Self.expectNoUI(query)
            reads.setValue(reads.value + 1)
            return (errSecInteractionNotAllowed, nil)
        } operation: { try #require(try Self.load(envelope)) }
        #expect(reads.value == accounts.count)
        #expect(session.accessToken.isEmpty)
        #expect(!session.isUsable)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CursorSessionStore(fileURL: directory.appendingPathComponent("session.json"))
        let stale = try CursorAppAuthSession(accessToken: makeCursorAppAuthToken(subject: "auth0|old-account"))
            .makeCookie()
        let browser = try #require(HTTPCookie(properties: [
            .name: "WorkosCursorSessionToken", .value: "synthetic-browser-session",
            .domain: "cursor.com", .path: "/", .secure: true,
        ]))
        await store.setCookies([stale, browser])
        let probe = CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0),
            browserCookieImportOrder: [],
            appAuthStore: CursorAppAuthSessionProviderStub(session: session),
            sessionStore: store,
            conditionalMutationCoordinator: CookieHeaderCache.ConditionalMutationCoordinator())
        let header = try await KeychainCacheStore.withServiceOverrideForTesting("cursor-encryption-\(UUID())") {
            try await KeychainCacheStore.withImplicitTestStoreForTesting {
                try await CookieHeaderCache
                    .withLegacyBaseURLOverrideForTesting(directory.appendingPathComponent("legacy")) {
                        try await probe.resolveSession { cookieHeader, _ in cookieHeader }
                    }
            }
        }
        #expect(header == "WorkosCursorSessionToken=synthetic-browser-session")
        #expect(await store.getCookies().allSatisfy { !CursorAppAuthSession.isPersistedCookie($0) })
    }

    @Test(arguments: [["Cursor Key"], ["Cursor"], ["Cursor Key", "Cursor"]])
    func `background and settings cannot promote an untrusted Cursor key`(accounts: [String]) throws {
        let envelope = try Self.envelope(makeCursorAppAuthToken())
        for settings in [false, true] {
            try Self.withKeychain(
                accounts: accounts,
                preflight: .interactionRequired,
                interaction: settings ? .userInitiated : .background)
            { _ in
                Issue.record("No secret read is allowed")
                return (errSecSuccess, nil)
            } operation: {
                try BrowserCookieAccessGate.withExplicitRetry {
                    try BrowserCookieKeychainAccessGate.$isUserInteractionDisallowed.withValue(settings) {
                        let session = try #require(try Self.load(envelope))
                        #expect(!session.isUsable)
                    }
                }
            }
        }
    }

    @Test(arguments: [["Cursor Key"], ["Cursor"], ["Cursor Key", "Cursor"]])
    func `manual Cursor read shares one allowance with browser Safe Storage`(accounts: [String]) throws {
        let envelope = try Self.envelope(makeCursorAppAuthToken())
        let reads = LockIsolated(0)
        try Self
            .withKeychain(accounts: accounts, preflight: .interactionRequired, interaction: .userInitiated) { query in
                #expect(query[kSecUseAuthenticationContext as String] == nil)
                #expect(query[kSecUseAuthenticationUI as String] == nil)
                reads.setValue(reads.value + 1)
                return (errSecSuccess, Data(Self.password.utf8))
            } operation: {
                try BrowserCookieAccessGate.withExplicitRetry {
                    let first = try Self.load(envelope)
                    let second = try Self.load(envelope)
                    #expect(first?.isUsable == true)
                    #expect(second?.isUsable == false)
                    #expect(!BrowserCookieAccessGate.claimCredentialRead(service: "Chrome Safe Storage"))
                }
            }
        #expect(reads.value == 1)
    }

    @Test(arguments: [["Cursor Key"], ["Cursor"], ["Cursor Key", "Cursor"]])
    func `manual denial cooldown covers both account names and the next action`(accounts: [String]) throws {
        let envelope = try Self.envelope(makeCursorAppAuthToken())
        let reads = LockIsolated(0)
        try Self.withKeychain(accounts: accounts, preflight: .interactionRequired, interaction: .userInitiated) { _ in
            reads.setValue(reads.value + 1)
            return (errSecUserCanceled, nil)
        } operation: {
            for _ in 0..<2 {
                try BrowserCookieAccessGate.withExplicitRetry {
                    let session = try Self.load(envelope)
                    #expect(session?.isUsable == false)
                }
            }
        }
        #expect(reads.value == 1)
    }

    @Test(arguments: [true, false])
    func `current key is preferred with legacy fallback after decryption fails`(currentKeyMatches: Bool) throws {
        let token = try makeCursorAppAuthToken()
        let envelope = try Self.envelope(token)
        let accounts = ["Cursor Key", "Cursor"]
        let reads = LockIsolated<[String]>([])
        let session = try Self.withKeychain(accounts: accounts) { query in
            Self.expectNoUI(query)
            let account = query[kSecAttrAccount as String] as? String ?? ""
            reads.setValue(reads.value + [account])
            let matches = (account == "Cursor Key") == currentKeyMatches
            return (errSecSuccess, Data((matches ? Self.password : "wrong-synthetic-password").utf8))
        } operation: { try #require(try Self.load(envelope)) }
        #expect(session.accessToken == token)
        #expect(session.isUsable)
        #expect(reads.value == (currentKeyMatches ? ["Cursor Key"] : accounts))
    }

    @Test
    func `failed interactive decryption cannot claim another account or browser prompt`() throws {
        let envelope = try Self.envelope(makeCursorAppAuthToken())
        let reads = LockIsolated(0)
        try Self.withKeychain(
            accounts: ["Cursor Key", "Cursor"],
            preflight: .interactionRequired,
            interaction: .userInitiated)
        { query in
            #expect(query[kSecUseAuthenticationContext as String] == nil)
            #expect(query[kSecUseAuthenticationUI as String] == nil)
            reads.setValue(reads.value + 1)
            return (errSecSuccess, Data("wrong-synthetic-password".utf8))
        } operation: {
            try BrowserCookieAccessGate.withExplicitRetry {
                let session = try #require(try Self.load(envelope))
                #expect(session.accessToken.isEmpty)
                #expect(!session.isUsable)
                #expect(!BrowserCookieAccessGate.claimCredentialRead(service: "Chrome Safe Storage"))
            }
        }
        #expect(reads.value == 1)
    }

    @Test
    func `disabled Keychain access skips both account names`() throws {
        let envelope = try Self.envelope(makeCursorAppAuthToken())
        try Self.withKeychain(accounts: ["Cursor Key", "Cursor"]) { _ in
            Issue.record("Disabled Keychain access must not read any secret")
            return (errSecSuccess, nil)
        } operation: {
            try KeychainAccessGate.withTaskOverrideForTesting(true) {
                try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                    Issue.record("Disabled Keychain access must not inspect any item")
                    return .notFound
                } operation: {
                    let session = try #require(try Self.load(envelope))
                    #expect(session.accessToken.isEmpty)
                    #expect(!session.isUsable)
                }
            }
        }
    }

    @Test(arguments: ["Cursor Key", "Cursor"])
    func `encrypted app database reaches usage fetch with JWT identity fallback`(account: String) async throws {
        let root = CodexCredentialFixtures.root
        let token = try makeCursorAppAuthToken(
            subject: "auth0|encrypted-pipeline",
            email: "encrypted-pipeline@example.test")
        let databaseURL = root.appendingPathComponent("state.vscdb")
        try Self.writeEncryptedFetchDatabase(Self.envelope(token), at: databaseURL)
        let databaseBefore = try Data(contentsOf: databaseURL)
        let expectedCookie = "WorkosCursorSessionToken=encrypted-pipeline%3A%3A" + token
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.host == "cursor-encrypted.test")
            #expect(request.value(forHTTPHeaderField: "Cookie") == expectedCookie)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let body: String
            let status: Int
            switch url.path {
            case "/api/usage-summary":
                status = 200
                body = """
                {"membershipType":"pro","individualUsage":{"plan":{
                  "used":1500,"limit":5000,"totalPercentUsed":30.0
                }}}
                """
            case "/api/auth/me":
                status = 503
                body = "{}"
            case "/api/dashboard/get-sand-usage-status":
                status = 404
                body = "{}"
            case "/api/usage":
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "user" })?.value == "encrypted-pipeline")
                status = 200
                body = #"{"gpt-4":{"numRequests":12,"numRequestsTotal":17,"maxRequestUsage":100}}"#
            default:
                Issue.record("Unexpected encrypted-session request: \(url.path)")
                throw URLError(.badURL)
            }
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), response)
        }
        let store = CursorSessionStore(fileURL: root.appendingPathComponent("session.json"))
        let probe = try CursorStatusProbe(
            baseURL: #require(URL(string: "https://cursor-encrypted.test")),
            browserDetection: BrowserDetection(
                homeDirectory: root.path,
                cacheTTL: 0,
                now: Date.init,
                fileExists: { _ in false },
                directoryContents: { _ in nil },
                applicationURLs: { _ in [] },
                profileAccessIssue: { _ in nil }),
            browserCookieImportOrder: [],
            urlSession: transport,
            appAuthStore: CursorAppAuthStore(dbPath: databaseURL.path),
            sessionStore: store,
            persistAppAuthSession: { await store.persistAppSession($0) },
            conditionalMutationCoordinator: CookieHeaderCache.ConditionalMutationCoordinator())
        let reads = LockIsolated<[String]>([])
        let snapshot = try await Self.withEncryptedFetchKeychain(account: account, reads: reads, root: root) {
            let result = try await probe.fetch(allowCachedSessions: false)
            let cached = try #require(CookieHeaderCache.load(provider: .cursor))
            #expect(cached.cookieHeader == expectedCookie)
            #expect(cached.sourceLabel == "Cursor.app local auth")
            return result
        }
        #expect(snapshot.planPercentUsed == 30)
        #expect(snapshot.requestsUsed == 17)
        #expect(snapshot.requestsLimit == 100)
        #expect(snapshot.accountID == "auth0|encrypted-pipeline")
        #expect(snapshot.accountEmail == "encrypted-pipeline@example.test")
        #expect(reads.value == [account])
        #expect(await transport.requests().compactMap { $0.url?.path }.sorted() == [
            "/api/auth/me",
            "/api/dashboard/get-sand-usage-status",
            "/api/usage",
            "/api/usage-summary",
        ])
        let persisted = await store.getCookies()
        #expect(persisted.count == 1)
        #expect(persisted.first?.value == "encrypted-pipeline%3A%3A" + token)
        #expect(persisted.allSatisfy(CursorAppAuthSession.isPersistedCookie))
        #expect(try Data(contentsOf: databaseURL) == databaseBefore)
    }

    private static func expectNoUI(_ query: [String: Any]) {
        #expect((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
        #expect(query[kSecUseAuthenticationUI as String] as? String == KeychainNoUIQuery.uiFailPolicyForTesting())
    }

    static func withKeychain<T>(
        accounts: [String] = ["Cursor"],
        preflight: KeychainAccessPreflight.Outcome = .allowed,
        interaction: ProviderInteraction = .background,
        read: @escaping @Sendable ([String: Any]) -> (OSStatus, Data?) = { query in
            Self.expectNoUI(query)
            return (errSecSuccess, Data(Self.password.utf8))
        },
        operation: () throws -> T) rethrows -> T
    {
        let lookup: @Sendable ([String: Any]) -> (OSStatus, Data?) = { query in
            #expect(query[kSecAttrService as String] as? String == "Cursor Safe Storage")
            #expect(accounts.contains(query[kSecAttrAccount as String] as? String ?? ""))
            #expect(query[kSecReturnData as String] as? Bool == true)
            return read(query)
        }
        let promptHandler = BrowserCookieKeychainPromptHandler.handler
        BrowserCookieKeychainPromptHandler.handler = nil
        defer { BrowserCookieKeychainPromptHandler.handler = promptHandler }
        return try KeychainAccessGate.withTaskOverrideForTesting(false) {
            try BrowserCookieAccessGate.withIsolatedStateForTesting {
                try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { service, queriedAccount in
                    #expect(service == "Cursor Safe Storage")
                    #expect(["Cursor Key", "Cursor"].contains(queriedAccount ?? ""))
                    return accounts.contains(queriedAccount ?? "") ? preflight : .notFound
                } operation: {
                    try ChromiumSafeStorage.$readOverrideForTesting.withValue(lookup) {
                        try ProviderInteractionContext.$current.withValue(interaction, operation: operation)
                    }
                }
            }
        }
    }

    static func envelope(_ token: String) throws -> String {
        try self.envelope(Data(token.utf8))
    }

    static func envelope(_ plaintext: Data) throws -> String {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let derived = key.withUnsafeMutableBytes { keyBytes in
            Self.password.withCString { password in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        password,
                        Self.password.utf8.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        kCCKeySizeAES128)
                }
            }
        }
        try #require(derived == kCCSuccess)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var encrypted = Data(count: plaintext.count + kCCBlockSizeAES128)
        let capacity = encrypted.count
        var count = 0
        let result = encrypted.withUnsafeMutableBytes { output in
            plaintext.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            input.baseAddress,
                            plaintext.count,
                            output.baseAddress,
                            capacity,
                            &count)
                    }
                }
            }
        }
        try #require(result == kCCSuccess)
        encrypted.count = count
        return "cursor-safe-storage:v1:" + (Data("v10".utf8) + encrypted).base64EncodedString()
    }

    static func load(_ token: String) throws -> CursorAppAuthSession? {
        try self.withDatabase(token) { try CursorAppAuthStore(dbPath: $0).loadSession() }
    }

    static func withDatabase<T>(_ token: String, operation: (String) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.vscdb").path
        var db: OpaquePointer?
        try #require(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, "CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value TEXT)", nil, nil, nil) ==
            SQLITE_OK)
        var stmt: OpaquePointer?
        try #require(sqlite3_prepare_v2(
            db,
            "INSERT INTO ItemTable VALUES('cursorAuth/accessToken', ?)",
            -1,
            &stmt,
            nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        try #require(sqlite3_bind_text(stmt, 1, token, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) ==
            SQLITE_OK)
        try #require(sqlite3_step(stmt) == SQLITE_DONE)
        return try operation(path)
    }

    private static func writeEncryptedFetchDatabase(_ envelope: String, at url: URL) throws {
        var database: OpaquePointer?
        try #require(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO ItemTable VALUES('cursorAuth/accessToken', '\(envelope)');
        """
        try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
    }

    private static func withEncryptedFetchKeychain<T>(
        account: String,
        reads: LockIsolated<[String]>,
        root: URL,
        operation: () async throws -> T) async rethrows -> T
    {
        let lookup: @Sendable ([String: Any]) -> (OSStatus, Data?) = { query in
            Self.expectNoUI(query)
            #expect(query[kSecAttrService as String] as? String == "Cursor Safe Storage")
            #expect(query[kSecAttrAccount as String] as? String == account)
            #expect(query[kSecReturnData as String] as? Bool == true)
            reads.setValue(reads.value + [query[kSecAttrAccount as String] as? String ?? ""])
            return (errSecSuccess, Data(Self.password.utf8))
        }
        return try await KeychainCacheStore.withServiceOverrideForTesting("cursor-encrypted-fetch-\(UUID())") {
            try await KeychainCacheStore.withImplicitTestStoreForTesting {
                try await CookieHeaderCache.withLegacyBaseURLOverrideForTesting(root.appendingPathComponent("legacy")) {
                    try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                        try await KeychainAccessPreflight
                            .withCheckGenericPasswordOverrideForTesting { service, queried in
                                #expect(service == "Cursor Safe Storage")
                                #expect(["Cursor Key", "Cursor"].contains(queried ?? ""))
                                return queried == account ? .allowed : .notFound
                            } operation: {
                                try await ChromiumSafeStorage.$readOverrideForTesting.withValue(lookup) {
                                    try await ProviderInteractionContext.$current.withValue(
                                        .background,
                                        operation: operation)
                                }
                            }
                    }
                }
            }
        }
    }
}
