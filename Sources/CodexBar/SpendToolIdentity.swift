import CodexBarCore
import Foundation

/// Stable presentation identity for the local product that emitted usage history.
///
/// Provider identity answers "who made the model"; tool identity answers "which app or
/// harness used it". Keeping the two separate prevents a Kimi model used in Cursor from being
/// presented as though Kimi Code produced the history.
struct SpendToolIdentity: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case desktop
        case cli
        case ide
        case extensionTool
        case api
        case other

        var displayName: String {
            switch self {
            case .desktop: "Desktop"
            case .cli: "CLI"
            case .ide: "IDE"
            case .extensionTool: "Extension"
            case .api: "API"
            case .other: "Tool"
            }
        }
    }

    let displayName: String
    let kind: Kind

    static func resolve(
        provider: UsageProvider,
        sourceName: String,
        providerName: String) -> Self
    {
        let source = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let family = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = source.lowercased()

        if normalized.contains(" cli") || normalized.hasSuffix("cli") {
            return Self(displayName: source, kind: .cli)
        }
        if normalized.contains("desktop") {
            return Self(displayName: source, kind: .desktop)
        }
        if normalized.contains("extension") || normalized.contains("copilot") {
            return Self(displayName: source, kind: .extensionTool)
        }
        if normalized.contains(" api") || normalized.hasSuffix("api") {
            return Self(displayName: source, kind: .api)
        }

        let sourceIsFamily = source.localizedCaseInsensitiveCompare(family) == .orderedSame
        switch provider {
        case .codex:
            return Self(displayName: sourceIsFamily ? "Codex Desktop" : source, kind: .desktop)
        case .claude:
            return Self(displayName: sourceIsFamily ? "Claude Code" : source, kind: .cli)
        case .cursor:
            return Self(displayName: sourceIsFamily ? "Cursor" : source, kind: .ide)
        case .antigravity:
            return Self(displayName: sourceIsFamily ? "Antigravity" : source, kind: .ide)
        case .kimi:
            return Self(displayName: sourceIsFamily ? "Kimi Code CLI" : source, kind: .cli)
        case .gemini:
            return Self(displayName: sourceIsFamily ? "Gemini CLI" : source, kind: .cli)
        case .minimax:
            return Self(displayName: sourceIsFamily ? "MiniMax Code" : source, kind: .desktop)
        case .opencode, .opencodego:
            return Self(displayName: sourceIsFamily ? "OpenCode CLI" : source, kind: .cli)
        case .zed, .qoder:
            return Self(displayName: sourceIsFamily ? family : source, kind: .ide)
        case .copilot:
            return Self(displayName: sourceIsFamily ? "GitHub Copilot" : source, kind: .extensionTool)
        default:
            return Self(displayName: source.isEmpty ? family : source, kind: .other)
        }
    }
}
