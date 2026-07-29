import CodexBarCore
import Foundation

/// Reader-facing subscription label for the private local dashboard.
///
/// Share cards intentionally use `ShareStatsSubscriptionName`'s closed allow-list. The local
/// dashboard can be more capable: it first uses that curated catalog, then safely humanizes a new
/// provider plan returned in `loginMethod`. This makes future provider tiers appear automatically
/// without confusing authentication methods or account identifiers for plan names.
struct SpendSubscriptionPlan: Equatable, Sendable {
    let displayName: String

    static func from(snapshot: UsageSnapshot?, provider: UsageProvider) -> Self? {
        if let curated = ShareStatsSubscriptionName.from(snapshot: snapshot, provider: provider) {
            return Self(displayName: curated.displayName)
        }
        guard let identity = snapshot?.identity(for: provider),
              let raw = identity.loginMethod?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              !self.matchesAccountIdentity(raw, identity: identity),
              !self.looksLikeAuthenticationMethod(raw)
        else { return nil }

        let cleaned = UsageFormatter.cleanPlanName(raw)
        return Self(displayName: cleaned.isEmpty ? raw : cleaned)
    }

    private static func matchesAccountIdentity(
        _ value: String,
        identity: ProviderIdentitySnapshot) -> Bool
    {
        [identity.accountEmail, identity.accountOrganization]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { $0.localizedCaseInsensitiveCompare(value) == .orderedSame }
    }

    private static func looksLikeAuthenticationMethod(_ value: String) -> Bool {
        let normalized = value.lowercased()
        if normalized.contains("@") || normalized.contains("://") { return true }
        if [
            "api spend", "balance", "credits", "remaining", "usage", "spent", "this month",
        ].contains(where: normalized.contains) {
            return true
        }
        return [
            "api key", "apikey", "oauth", "browser cookie", "cookie", "access token",
            "bearer token", "service account", "admin api",
        ].contains(normalized)
    }
}
