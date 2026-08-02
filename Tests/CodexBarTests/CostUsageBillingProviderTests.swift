import CodexBarCore
import Testing

struct CostUsageBillingProviderTests {
    @Test
    func `outer explicit route owns nested billing chains`() {
        #expect(CostUsageBillingProvider.providerID(fromNamespacedModel: "openrouter/anthropic/claude-sonnet-4")
            == UsageProvider.openrouter.rawValue)
        #expect(CostUsageBillingProvider.providerID(fromNamespacedModel: "gateway/team/moonshot/kimi-k2")
            == UsageProvider.moonshot.rawValue)
        #expect(CostUsageBillingProvider.providerID(fromNamespacedModel: "gateway/team/moonshotai/kimi-k2")
            == UsageProvider.moonshot.rawValue)
    }

    @Test
    func `plain family labels are not billing evidence`() {
        #expect(CostUsageBillingProvider.providerID(fromNamespacedModel: "MiniMax-M3") == nil)
        #expect(CostUsageBillingProvider.providerID(fromNamespacedModel: "claude-sonnet-4") == nil)
        #expect(CostUsageBillingProvider.providerID(fromNamespacedModel: "minimax/MiniMax-M3")
            == UsageProvider.minimax.rawValue)
    }
}
