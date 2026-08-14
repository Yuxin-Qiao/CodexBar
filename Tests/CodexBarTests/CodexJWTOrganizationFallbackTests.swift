import Foundation
import Testing
@testable import CodexBarCore

struct CodexJWTOrganizationFallbackTests {
    @Test
    func `auth identity falls back to the first JWT organization`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-jwt-organization-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let payload: [String: Any] = [
            "email": "user@example.com",
            "organizations": [["id": "  "], ["id": "org-from-jwt"]],
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let encodedPayload = payloadData
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let idToken = ["test-header", encodedPayload, "test-signature"].joined(separator: ".")
        let auth: [String: Any] = [
            "tokens": [
                "access_token": "access-token",
                "refresh_token": "refresh-token",
                "id_token": idToken,
            ],
        ]
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: auth)
            .write(to: home.appendingPathComponent("auth.json"))

        let account = UsageFetcher(environment: ["CODEX_HOME": home.path]).loadAuthBackedCodexAccount()
        #expect(account.identity == .providerAccount(id: "org-from-jwt"))
        #expect(account.email == "user@example.com")
    }

    @Test
    func `blank direct account claims fall through to the first JWT organization`() throws {
        let payload: [String: Any] = [
            "https://api.openai.com/auth": ["chatgpt_account_id": "  "],
            "chatgpt_account_id": "\n\t",
            "organizations": [["id": "  "], ["id": "org-after-blank-claims"]],
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let encodedPayload = payloadData
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let idToken = ["test-header", encodedPayload, "test-signature"].joined(separator: ".")

        let credentials = CodexOAuthCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: idToken,
            accountId: " \t",
            lastRefresh: Date())

        #expect(credentials.resolvedAccountId == "org-after-blank-claims")
    }
}
