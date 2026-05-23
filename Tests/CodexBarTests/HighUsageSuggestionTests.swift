import CodexBarCore
import Foundation
import Testing

struct HighUsageSuggestionTests {
    @Test
    func `low usage returns no suggestions`() {
        let provider = HighUsageSuggestionProvider.usedPercent(50)
        #expect(provider.suggestions().isEmpty)
    }

    @Test
    func `usage at threshold returns suggestions`() {
        let provider = HighUsageSuggestionProvider.usedPercent(80)
        let suggestions = provider.suggestions()
        #expect(!suggestions.isEmpty)
        #expect(suggestions.allSatisfy { $0.priority == .normal })
    }

    @Test
    func `usage at critical threshold returns elevated priority`() {
        let provider = HighUsageSuggestionProvider.usedPercent(95)
        let suggestions = provider.suggestions()
        #expect(!suggestions.isEmpty)
        #expect(suggestions.allSatisfy { $0.priority == .elevated })
    }

    @Test
    func `usage above critical threshold returns elevated priority`() {
        let provider = HighUsageSuggestionProvider.usedPercent(99)
        let suggestions = provider.suggestions()
        #expect(!suggestions.isEmpty)
        #expect(suggestions.allSatisfy { $0.priority == .elevated })
    }

    @Test
    func `usage at exactly 100 percent returns suggestions`() {
        let provider = HighUsageSuggestionProvider.usedPercent(100)
        let suggestions = provider.suggestions()
        #expect(!suggestions.isEmpty)
        #expect(suggestions.allSatisfy { $0.priority == .elevated })
    }

    @Test
    func `high usage returns four suggestions`() {
        let provider = HighUsageSuggestionProvider.usedPercent(85)
        let suggestions = provider.suggestions()
        #expect(suggestions.count == 4)
    }

    @Test
    func `normal priority title is Usage is high`() {
        let provider = HighUsageSuggestionProvider.usedPercent(80)
        let suggestions = provider.suggestions()
        #expect(suggestions.allSatisfy { $0.title == "Usage is high" })
    }

    @Test
    func `elevated priority title is Usage is very high`() {
        let provider = HighUsageSuggestionProvider.usedPercent(95)
        let suggestions = provider.suggestions()
        #expect(suggestions.allSatisfy { $0.title == "Usage is very high" })
    }
}
