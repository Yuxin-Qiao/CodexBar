import Foundation

/// Resolves the account scope used by Codex OAuth requests without exposing JWT contents.
extension CodexOAuthCredentials {
    /// Returns the first nonblank account claim, falling back to the first nonblank organization ID.
    public var resolvedAccountId: String? {
        CodexOAuthAccountIdentityResolver.resolve(accountId: self.accountId, idToken: self.idToken)
    }
}

enum CodexOAuthAccountIdentityResolver {
    static func resolve(accountId: String?, idToken: String?) -> String? {
        let payload = idToken.flatMap(Self.payload(from:))
        let auth = payload?["https://api.openai.com/auth"] as? [String: Any]
        let candidates = [
            accountId,
            auth?["chatgpt_account_id"] as? String,
            payload?["chatgpt_account_id"] as? String,
        ]
        for candidate in candidates {
            if let normalized = Self.normalized(candidate) {
                return normalized
            }
        }

        guard let organizations = payload?["organizations"] as? [[String: Any]] else { return nil }
        for organization in organizations {
            if let normalized = Self.normalized(organization["id"] as? String) {
                return normalized
            }
        }
        return nil
    }

    static func payload(from token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var padded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 {
            padded.append("=")
        }
        guard let data = Data(base64Encoded: padded) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
