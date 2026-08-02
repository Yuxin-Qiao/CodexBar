import CodexBarCore
import Foundation

// MARK: - SpendModelIdentity

/// Normalized cross-provider identity for one reported model name.
///
/// The spend dashboard's "Models" card merges usage across providers, so the same model must land on a
/// single row no matter how each source spells it: Claude Code reports `claude-sonnet-4-5`, Vertex reports
/// `anthropic/claude-sonnet-4-5-20250929`, and OpenAI snapshots report `gpt-5-2025-08-07` next to `gpt-5`.
///
/// Normalization is deliberately conservative — it only removes decoration that provably does not
/// identify a different model:
/// - surrounding whitespace and repeated internal whitespace;
/// - CLIProxyAPI-style `(high)` reasoning-tier annotations (recognized tier names only);
/// - vendor routing path prefixes (`anthropic/…`, `openai/…`, `openrouter/…`, or the provider's own name);
/// - trailing snapshot dates (`-YYYYMMDD` and `-YYYY-MM-DD`, valid calendar dates only);
/// - Claude version punctuation and order (`claude-3.5-sonnet` ≡ `claude-3-5-sonnet` ≡ `claude-sonnet-3-5`).
///
/// Semantic suffixes that denote a genuinely different model (`-codex`, `-thinking`, `-mini`, `-latest`, …)
/// are never stripped: when unsure, spellings keep distinct identities and stay on separate rows.
struct SpendModelIdentity: Equatable, Sendable {
    /// Lowercase merge key shared by every spelling of the same model.
    let id: String
    /// Human-facing label: a curated alias when one exists, else the stripped name in its original casing.
    let displayName: String

    init(rawName: String, provider: UsageProvider? = nil) {
        let collapsed = Self.collapsingWhitespace(rawName)
        let withoutTier = Self.strippingReasoningTierSuffix(collapsed)
        let withoutPrefix = Self.strippingVendorPathPrefixes(withoutTier, providerHint: provider?.rawValue)
        let pretty = Self.strippingTrailingDateStamp(withoutPrefix)
        let canonical = Self.canonicalID(for: pretty)
        if let alias = Self.displayAliases[canonical] {
            self.id = alias.lowercased()
            self.displayName = alias
        } else {
            self.id = canonical
            self.displayName = Self.brandStyledDisplayName(pretty, canonicalID: canonical)
        }
    }

    // MARK: - Normalization steps

    /// Trims the name and collapses every internal whitespace run to a single space.
    private static func collapsingWhitespace(_ name: String) -> String {
        name.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Strips a trailing `(tier)` reasoning-effort annotation added by routing proxies. Only recognized
    /// tier names are stripped, and a space before the parenthesis refuses the strip (the annotation is
    /// then treated as part of the name), so unknown parenthesized suffixes keep a distinct identity.
    private static func strippingReasoningTierSuffix(_ name: String) -> String {
        guard name.hasSuffix(")"),
              let openingParen = name.lastIndex(of: "(")
        else { return name }
        let base = name[..<openingParen]
        let tier = name[name.index(after: openingParen)..<name.index(before: name.endIndex)]
        guard !base.isEmpty,
              base == base.trimmingCharacters(in: .whitespaces),
              self.reasoningTierSuffixes.contains(tier.lowercased())
        else { return name }
        return String(base)
    }

    /// Drops leading `/`-separated segments that are vendor routing prefixes (`anthropic/…`,
    /// `openrouter/anthropic/…`) or the reporting provider's own name, keeping the terminal model
    /// segment. Unknown leading segments are kept, so a genuinely namespaced name never collapses onto
    /// an unrelated one. A bare vendor token with no following segment is left untouched.
    private static func strippingVendorPathPrefixes(_ name: String, providerHint: String?) -> String {
        var segments = name.split(separator: "/", omittingEmptySubsequences: true)
        guard !segments.isEmpty else { return name }
        let hint = providerHint?.lowercased()
        while segments.count > 1 {
            let head = segments[0].lowercased()
            guard self.vendorPathPrefixes.contains(head) || head == hint else { break }
            segments.removeFirst()
        }
        return segments.joined(separator: "/")
    }

    /// Strips one trailing snapshot date (`-YYYYMMDD` or `-YYYY-MM-DD`). The digits must form a
    /// plausible calendar date (year 1900–2099, month 1–12, day 1–31), so version-ish suffixes such as
    /// `deepseek-v3-0324` or `gpt-5-20251345` are never eaten. A date with no model name before it is
    /// kept as-is.
    private static func strippingTrailingDateStamp(_ name: String) -> String {
        if name.count > 11 {
            let suffix = name.suffix(11)
            let parts = suffix.split(separator: "-", omittingEmptySubsequences: false)
            if parts.count == 4, parts[0].isEmpty,
               let year = Self.paddedNumber(parts[1], digits: 4),
               let month = Self.paddedNumber(parts[2], digits: 2),
               let day = Self.paddedNumber(parts[3], digits: 2),
               self.looksLikeSnapshotDate(year: year, month: month, day: day)
            {
                return String(name.dropLast(11))
            }
        }
        if name.count > 9 {
            let suffix = name.suffix(9)
            if suffix.hasPrefix("-") {
                let digits = suffix.dropFirst()
                if let year = Self.paddedNumber(digits.prefix(4), digits: 4),
                   let month = Self.paddedNumber(digits.dropFirst(4).prefix(2), digits: 2),
                   let day = Self.paddedNumber(digits.suffix(2), digits: 2),
                   self.looksLikeSnapshotDate(year: year, month: month, day: day)
                {
                    return String(name.dropLast(9))
                }
            }
        }
        return name
    }

    /// Lowercase merge key: Claude version dots (`claude-3.5` → `claude-3-5`) and the legacy
    /// `claude-<major>-<minor>-<family>` segment order are folded so API-style and Claude Code-style
    /// spellings of the same model merge.
    private static func canonicalID(for name: String) -> String {
        let lowercased = name.lowercased()
        let dotsNormalized = Self.normalizingClaudeVersionDots(lowercased)
        return Self.normalizingClaudeVersionOrder(dotsNormalized)
    }

    /// Rewrites `.` to `-` between digits, but only for Claude names: `claude-3.5-sonnet` and the
    /// `claude-3-5-sonnet` spelling refer to one model, while dots in other families (`k2.5`, …) are
    /// part of the name and stay untouched.
    private static func normalizingClaudeVersionDots(_ name: String) -> String {
        guard name.contains("claude"), name.contains(".") else { return name }
        let characters = Array(name)
        var result = String()
        result.reserveCapacity(characters.count)
        for index in characters.indices {
            let character = characters[index]
            if character == ".",
               index > characters.startIndex,
               index < characters.index(before: characters.endIndex),
               characters[index - 1].isASCII, characters[index - 1].isNumber,
               characters[index + 1].isASCII, characters[index + 1].isNumber
            {
                result.append("-")
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Rewrites the legacy `claude-<major>-<minor>-<family>` order (Anthropic API, Bedrock, and Vertex
    /// spelling) to the `claude-<family>-<major>-<minor>` order Claude Code reports. The match is exact
    /// — two numeric segments plus a known family and nothing else — so unrelated names never reorder.
    private static func normalizingClaudeVersionOrder(_ name: String) -> String {
        guard name.hasPrefix("claude-") else { return name }
        let parts = name.dropFirst("claude-".count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              Self.isASCIINumber(parts[0]),
              Self.isASCIINumber(parts[1]),
              self.claudeVersionFamilies.contains(String(parts[2]))
        else { return name }
        return "claude-\(parts[2])-\(parts[0])-\(parts[1])"
    }

    // MARK: - Lookup tables and parsing helpers

    /// Reasoning-effort tier names a routing proxy may append as `(tier)`.
    private static let reasoningTierSuffixes: Set<String> = [
        "minimal", "low", "medium", "high", "xhigh", "auto", "none",
    ]

    /// Vendor and gateway tokens that only route to a model when they appear as a leading path segment.
    private static let vendorPathPrefixes: Set<String> = [
        "anthropic", "openai", "google", "gemini", "moonshot", "moonshotai", "kimi", "kimi-code",
        "deepseek", "xai", "x-ai", "zai", "z-ai", "meta", "meta-llama", "mistral", "mistralai",
        "azure", "azureopenai", "bedrock", "vertex", "vertexai", "vertex_ai", "openrouter",
        "qwen", "cohere", "perplexity", "minimax",
    ]

    /// Claude family names allowed in the legacy `claude-<major>-<minor>-<family>` order.
    private static let claudeVersionFamilies: Set<String> = ["opus", "sonnet", "haiku"]

    /// Curated pretty names for Kimi models, keyed by canonical id. Kept in sync with the historical
    /// `kimi-code/` prefix behavior: the prefix strips via `vendorPathPrefixes`, then these aliases
    /// provide the display casing.
    private static let displayAliases: [String: String] = [
        "k3": "Kimi K3",
        "kimi-k3": "Kimi K3",
        "k3-256k": "Kimi K3 (256K)",
        "kimi-k3-256k": "Kimi K3 (256K)",
        "k2.5": "Kimi K2.5",
        "kimi-k2.5": "Kimi K2.5",
        "k2": "Kimi K2",
        "kimi-k2": "Kimi K2",
        "kimi-for-coding": "Kimi for Coding",
        "kimi-for-coding-highspeed": "Kimi for Coding High-Speed",
        // Antigravity's internal Gemini/Claude codenames → the public model names they route to.
        "gemini-pro-default": "Gemini 3.1 Pro",
        "gemini-pro-agent": "Gemini 3.1 Pro",
        "gemini-3.1-pro": "Gemini 3.1 Pro",
        "gemini-3.1-pro-high": "Gemini 3.1 Pro",
        "gemini-3.1-pro-low": "Gemini 3.1 Pro",
        "gemini-3-pro": "Gemini 3 Pro",
        "gemini-3-pro-high": "Gemini 3 Pro",
        "gemini-3-pro-low": "Gemini 3 Pro",
        "gemini-3-flash": "Gemini 3 Flash",
        "gemini-3-flash-c": "Gemini 3 Flash",
        "gemini-default": "Gemini 3 Flash",
        "gemini-3-flash-a": "Gemini 3.5 Flash (High)",
        "gemini-3-flash-agent": "Gemini 3.5 Flash (High)",
        "gemini-3-flash-b": "Gemini 3.5 Flash (High)",
        "gemini-3.5-flash-high": "Gemini 3.5 Flash (High)",
        "gemini-3.5-flash-low": "Gemini 3.5 Flash (Medium)",
        "gemini-3.5-flash-medium": "Gemini 3.5 Flash (Medium)",
        "gemini-3.5-flash-extra-low": "Gemini 3.5 Flash (Low)",
        "gemini-3.6-flash": "Gemini 3.6 Flash",
        "claude-opus-4-6-thinking": "Claude Opus 4.6",
        "claude-sonnet-4-6-thinking": "Claude Sonnet 4.6",
        "claude-haiku-4-6-thinking": "Claude Haiku 4.6",
    ]

    /// Applies the public brand's casing and version style while preserving the canonical model
    /// identity. This is intentionally structural instead of a list of current model releases, so
    /// newly scanned models inherit a recognizable label without requiring a dashboard update.
    private static func brandStyledDisplayName(_ original: String, canonicalID: String) -> String {
        let parts = canonicalID.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let family = parts.first, parts.count > 1 else { return original }
        let tail = Array(parts.dropFirst())

        switch family {
        case "gpt":
            return self.gptDisplayName(tail)
        case "codex":
            return "Codex \(tail.map(self.modelTokenDisplayName).joined(separator: " "))"
        case "claude":
            return self.claudeDisplayName(tail)
        case "gemini":
            return "Gemini \(tail.map(self.modelTokenDisplayName).joined(separator: " "))"
        case "minimax":
            return "MiniMax \(tail.map(self.modelTokenDisplayName).joined(separator: " "))"
        case "deepseek":
            return "DeepSeek-\(tail.map(self.modelTokenDisplayName).joined(separator: "-"))"
        case "kimi":
            return "Kimi \(tail.map(self.modelTokenDisplayName).joined(separator: " "))"
        default:
            return original
        }
    }

    private static func gptDisplayName(_ parts: [String]) -> String {
        guard let version = parts.first else { return "GPT" }
        var result = "GPT-\(version)"
        for token in parts.dropFirst() {
            if token == "codex" {
                result += "-Codex"
            } else {
                result += " \(self.modelTokenDisplayName(token))"
            }
        }
        return result
    }

    private static func claudeDisplayName(_ parts: [String]) -> String {
        var result = ["Claude"]
        var index = 0
        while index < parts.count {
            if index + 1 < parts.count,
               self.isASCIINumber(parts[index]),
               self.isASCIINumber(parts[index + 1])
            {
                result.append("\(parts[index]).\(parts[index + 1])")
                index += 2
            } else {
                result.append(self.modelTokenDisplayName(parts[index]))
                index += 1
            }
        }
        return result.joined(separator: " ")
    }

    private static func modelTokenDisplayName(_ token: String) -> String {
        guard !token.isEmpty else { return token }
        if token == "mini" { return token }
        if let first = token.first,
           ["k", "m", "r", "v"].contains(String(first)),
           token.dropFirst().first?.isNumber == true
        {
            return token.uppercased()
        }
        return token.prefix(1).uppercased() + token.dropFirst()
    }

    /// Parses an ASCII digit run of exactly `digits` characters, rejecting anything else.
    private static func paddedNumber(_ text: some StringProtocol, digits: Int) -> Int? {
        guard text.count == digits, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    private static func isASCIINumber(_ text: some StringProtocol) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Plausibility check for snapshot dates: real model stamps use calendar-ish values, so loose
    /// bounds reject version fragments (`-0324`) and digit runs (`-12345678`) that are not dates.
    private static func looksLikeSnapshotDate(year: Int, month: Int, day: Int) -> Bool {
        (1900...2099).contains(year) && (1...12).contains(month) && (1...31).contains(day)
    }
}
