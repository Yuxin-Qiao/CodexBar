import SwiftUI

/// Keep the same dimension colors in the inline summary and its evidence popover.
struct SpendHarnessRatingStyle {
    let colorScheme: ColorScheme
    let contrast: ColorSchemeContrast

    var fillOpacity: Double {
        self.colorScheme == .dark ? 0.12 : 0.07
    }

    var borderOpacity: Double {
        self.contrast == .increased ? 0.65 : 0.18
    }

    func color(for dimension: SpendHarnessRating.Dimension) -> Color {
        switch dimension {
        case .cache: self.color(light: 0x0D7569, dark: 0x67DECA)
        case .response: self.color(light: 0x2466C6, dark: 0x8BB8FF)
        case .output: self.color(light: 0x7152C8, dark: 0xC1ACFF)
        case .duration: self.color(light: 0x95600B, dark: 0xF6C46D)
        }
    }

    func color(for band: SpendHarnessRating.Band?) -> Color {
        switch band {
        case .good: self.color(light: 0x17764F, dark: 0x7BD7AD)
        case .moderate: self.color(light: 0x95600B, dark: 0xF6C46D)
        case .poor: self.color(light: 0xB54449, dark: 0xFF9FA4)
        case nil: .secondary
        }
    }

    static func symbol(for dimension: SpendHarnessRating.Dimension) -> String {
        switch dimension {
        case .cache: "arrow.triangle.2.circlepath"
        case .response: "bolt.fill"
        case .output: "text.alignleft"
        case .duration: "clock"
        }
    }

    static func symbol(for band: SpendHarnessRating.Band?) -> String {
        switch band {
        case .good: "checkmark.circle.fill"
        case .moderate: "minus.circle.fill"
        case .poor: "exclamationmark.circle.fill"
        case nil: "ellipsis.circle"
        }
    }

    private func color(light: UInt32, dark: UInt32) -> Color {
        let value = self.colorScheme == .dark ? dark : light
        return Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1)
    }
}

struct SpendHarnessScoreBadge: View {
    let text: String
    let band: SpendHarnessRating.Band?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let style = SpendHarnessRatingStyle(colorScheme: self.colorScheme, contrast: self.contrast)
        let color = style.color(for: self.band)
        Label(self.text, systemImage: SpendHarnessRatingStyle.symbol(for: self.band))
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(style.fillOpacity), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(style.borderOpacity), lineWidth: 1))
            .fixedSize()
    }
}
