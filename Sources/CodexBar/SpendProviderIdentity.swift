import CodexBarCore
import Foundation

/// Canonical vendor identity used by every model-centric spend surface.
///
/// Tools are deliberately not vendors: Cursor can run Kimi, Antigravity can run Claude, and
/// Claude Code can be a harness for MiniMax. This resolver keeps that distinction in one place so
/// model icons, colors, labels, charts, and future exports cannot drift into separate heuristics.
enum SpendProviderIdentity {
    static func modelProvider(
        rawNames: some Sequence<String>,
        fallbackProviders: some Sequence<UsageProvider>) -> UsageProvider
    {
        for name in rawNames {
            if let provider = self.explicitModelProvider(name) {
                return provider
            }
        }
        for provider in fallbackProviders {
            return provider
        }
        return .openai
    }

    static func modelProvider(rawName: String, fallback: UsageProvider) -> UsageProvider {
        self.explicitModelProvider(rawName) ?? fallback
    }

    static func displayName(for provider: UsageProvider) -> String {
        ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
    }

    /// Explicit model-family detection. Generic provider ids/display names cover new providers
    /// automatically; aliases handle families whose public model ids differ from product ids.
    private static func explicitModelProvider(_ rawName: String) -> UsageProvider? {
        let normalized = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty, normalized != "<synthetic>" else { return nil }

        let components = normalized
            .split(whereSeparator: { $0 == "/" || $0 == ":" || $0 == "." || $0 == "-" || $0 == " " })
            .map(String.init)
        let first = components.first ?? normalized

        let aliases: [(matches: Bool, provider: UsageProvider)] = [
            (normalized.contains("claude") || first == "anthropic", .claude),
            (normalized.contains("gemini") || first == "google", .gemini),
            (normalized.contains("minimax"), .minimax),
            (normalized.contains("deepseek"), .deepseek),
            (
                normalized.contains("kimi") || normalized.contains("moonshot") ||
                    normalized == "k3" || normalized.hasPrefix("k3-"),
                .kimi),
            (
                normalized.contains("gpt") || normalized.hasPrefix("chatgpt") ||
                    normalized.hasPrefix("codex-") || Self.isOpenAIReasoningFamily(normalized),
                .openai),
            (normalized.contains("grok") || first == "xai", .grok),
            (
                normalized.contains("mistral") || normalized.contains("mixtral") ||
                    normalized.contains("codestral") || normalized.contains("devstral"),
                .mistral),
            (normalized.contains("qwen"), .alibaba),
            (normalized.contains("glm") || first == "zai", .zai),
        ]
        if let explicit = aliases.first(where: \.matches) {
            return explicit.provider
        }

        // The provider registry is the extensibility path: a newly added provider whose model id
        // begins with either its canonical id or public display name needs no dashboard change.
        return UsageProvider.allCases.first { provider in
            let id = provider.rawValue.lowercased()
            let display = self.displayName(for: provider).lowercased()
            return first == id || normalized.hasPrefix("\(id)/") ||
                normalized.hasPrefix("\(id)-") || normalized.hasPrefix("\(display)/") ||
                normalized.hasPrefix("\(display)-")
        }
    }

    private static func isOpenAIReasoningFamily(_ name: String) -> Bool {
        ["o1", "o3", "o4"].contains { family in
            name == family || name.hasPrefix("\(family)-")
        }
    }
}
