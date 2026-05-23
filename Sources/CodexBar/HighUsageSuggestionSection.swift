import AppKit
import CodexBarCore
import SwiftUI

struct HighUsageSuggestionSection: View {
    let suggestions: [HighUsageSuggestion]
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let first = suggestions.first, first.priority == .elevated {
                Text("High usage detected")
                    .font(.body)
                    .fontWeight(.medium)
            }
            ForEach(Array(self.suggestions.enumerated()), id: \.offset) { _, suggestion in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    Text(suggestion.body)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
