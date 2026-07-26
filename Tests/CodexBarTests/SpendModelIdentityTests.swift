import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendModelIdentityTests {
    @Test
    func `identity trims and collapses whitespace`() {
        #expect(Self.id("  claude-sonnet-4-5  ") == "claude-sonnet-4-5")
        #expect(Self.id("\n\tgpt-5\n") == "gpt-5")
        #expect(Self.id("test  model") == "test model")
    }

    @Test
    func `identity merges compact and dashed snapshot dates`() {
        #expect(Self.id("gpt-5-20250807") == "gpt-5")
        #expect(Self.id("gpt-5-2025-08-07") == "gpt-5")
        #expect(Self.id("gpt-5-2024-01-15") == Self.id("gpt-5-2025-08-07"))
        #expect(Self.id("claude-sonnet-4-5-20250929") == "claude-sonnet-4-5")
    }

    @Test
    func `identity rejects digit suffixes that are not valid dates`() {
        #expect(Self.id("gpt-5-20251345") == "gpt-5-20251345") // month 13 is not a date
        #expect(Self.id("test-12345678") == "test-12345678") // year 1234 is implausible
        #expect(Self.id("deepseek-v3-0324") == "deepseek-v3-0324") // short version suffix stays
        #expect(Self.id("gpt-5-20251345") != Self.id("gpt-5"))
    }

    @Test
    func `identity strips vendor routing prefixes but keeps unknown prefixes`() {
        #expect(Self.id("anthropic/claude-sonnet-4-5", provider: .vertexai) == "claude-sonnet-4-5")
        #expect(Self.id("openrouter/anthropic/claude-sonnet-4-5", provider: .openrouter) == "claude-sonnet-4-5")
        #expect(Self.id("openai/gpt-5", provider: .openai) == "gpt-5")
        #expect(Self.id("bedrock/claude-sonnet-4-5", provider: .bedrock) == "claude-sonnet-4-5")
        #expect(Self.id("acme-corp/gpt-5", provider: .openai) == "acme-corp/gpt-5")
        #expect(Self.id("acme-corp/gpt-5") != Self.id("gpt-5"))
    }

    @Test
    func `identity uses the provider name as an extra prefix hint`() {
        #expect(Self.id("cursor/gpt-5", provider: .cursor) == "gpt-5")
        #expect(Self.id("cursor/gpt-5", provider: .openai) == "cursor/gpt-5")
        #expect(Self.id("cursor/gpt-5") == "cursor/gpt-5")
    }

    @Test
    func `identity normalizes claude version punctuation and order`() {
        #expect(Self.id("claude-3.5-sonnet") == "claude-sonnet-3-5")
        #expect(Self.id("claude-3-5-sonnet") == "claude-sonnet-3-5")
        #expect(Self.id("claude-3.5-sonnet-20241022") == Self.id("claude-sonnet-3-5"))
        #expect(Self.id("claude-sonnet-4-5") == "claude-sonnet-4-5") // family-first order stays
        #expect(Self.id("claude-opus-4-5") != Self.id("claude-sonnet-4-5"))
    }

    @Test
    func `identity leaves dots in non claude names alone`() {
        #expect(Self.id("test-model-1.5-pro") == "test-model-1.5-pro")
        #expect(Self.id("test-model-1.5-pro") != Self.id("test-model-1-5-pro"))
    }

    @Test
    func `identity keeps kimi alias display names`() {
        let prefixed = SpendModelIdentity(rawName: "kimi-code/kimi-k2.5", provider: .kimi)
        #expect(prefixed.displayName == "Kimi K2.5")
        #expect(prefixed.id == "kimi k2.5")
        #expect(SpendModelIdentity(rawName: "K2", provider: .kimi).displayName == "Kimi K2")
        #expect(SpendModelIdentity(rawName: "k2.5", provider: .kimi).displayName == "Kimi K2.5")
        let coding = SpendModelIdentity(rawName: "kimi-code/kimi-for-coding-highspeed", provider: .kimi)
        #expect(coding.displayName == "Kimi for Coding High-Speed")
        #expect(SpendModelIdentity(rawName: "k3-256k", provider: .kimi).displayName == "Kimi K3 (256K)")
    }

    @Test
    func `identity names Antigravity aliases by their public model tier`() {
        #expect(SpendModelIdentity(
            rawName: "gemini-pro-default",
            provider: .antigravity).displayName == "Gemini 3.1 Pro")
        #expect(SpendModelIdentity(
            rawName: "gemini-3-flash-a",
            provider: .antigravity).displayName == "Gemini 3.5 Flash (High)")
        #expect(SpendModelIdentity(
            rawName: "gemini-3.5-flash-low",
            provider: .antigravity).displayName == "Gemini 3.5 Flash (Medium)")
        #expect(SpendModelIdentity(
            rawName: "gemini-3.5-flash-extra-low",
            provider: .antigravity).displayName == "Gemini 3.5 Flash (Low)")
        #expect(SpendModelIdentity(
            rawName: "gemini-default",
            provider: .antigravity).displayName == "Gemini 3 Flash")
    }

    @Test
    func `identity merges recognized proxy reasoning tier annotations only`() {
        #expect(Self.id("gpt-5(high)") == "gpt-5")
        #expect(Self.id("gpt-5(xhigh)") == Self.id("gpt-5"))
        #expect(Self.id("gpt-5(turbo)") == "gpt-5(turbo)") // unknown tiers stay distinct
        #expect(Self.id("gpt-5 (high)") == "gpt-5 (high)") // spaced annotation stays, conservatively
    }

    @Test
    func `identity never strips semantic model suffixes`() {
        #expect(Self.id("gpt-5-codex") != Self.id("gpt-5"))
        #expect(Self.id("gpt-5-mini") != Self.id("gpt-5"))
        #expect(Self.id("gpt-5-latest") != Self.id("gpt-5"))
        #expect(Self.id("claude-sonnet-4-5-thinking") != Self.id("claude-sonnet-4-5"))
    }

    @Test
    func `identity survives empty and garbage names`() {
        #expect(Self.id("").isEmpty)
        #expect(Self.id("   ").isEmpty)
        #expect(Self.id("///") == "///")
        #expect(Self.id("anthropic/") == "anthropic")
        #expect(Self.id("-20250807") == "-20250807") // a date dash with no model name stays
    }

    private static func id(_ rawName: String, provider: UsageProvider? = nil) -> String {
        SpendModelIdentity(rawName: rawName, provider: provider).id
    }
}
