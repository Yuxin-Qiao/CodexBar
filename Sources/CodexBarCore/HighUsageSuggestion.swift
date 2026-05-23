import Foundation

/// Provider-neutral suggestion shown when usage or spend is high.
public struct HighUsageSuggestion: Equatable, Sendable {
    public enum Priority: Int, Comparable, Sendable {
        case normal = 0
        case elevated = 1

        public static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let title: String
    public let body: String
    public let priority: Priority

    public init(title: String, body: String, priority: Priority = .normal) {
        self.title = title
        self.body = body
        self.priority = priority
    }
}

public enum HighUsageSuggestionProvider {
    case usedPercent(Double)

    public var suggestionThreshold: Double {
        80
    }

    public var criticalThreshold: Double {
        95
    }

    public func suggestions() -> [HighUsageSuggestion] {
        switch self {
        case let .usedPercent(percent):
            if percent < self.suggestionThreshold {
                return []
            }
            let priority: HighUsageSuggestion.Priority = percent >= self.criticalThreshold ? .elevated : .normal
            return Self.suggestionsForUsage(percent: percent, priority: priority)
        }
    }

    private static func suggestionsForUsage(
        percent: Double,
        priority: HighUsageSuggestion.Priority) -> [HighUsageSuggestion]
    {
        let title = if priority == .elevated {
            "Usage is very high"
        } else {
            "Usage is high"
        }

        return [
            HighUsageSuggestion(
                title: title,
                body: "Narrow the prompt scope before starting a large agent run.",
                priority: priority),
            HighUsageSuggestion(
                title: title,
                body: "Attach only the files or folders needed for the task.",
                priority: priority),
            HighUsageSuggestion(
                title: title,
                body: "Use a cheaper or smaller model for exploration and reserve premium models for final passes.",
                priority: priority),
            HighUsageSuggestion(
                title: title,
                body: "Check for background agents or repeated retry loops.",
                priority: priority),
        ]
    }
}
