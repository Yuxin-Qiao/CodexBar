import Foundation

public enum ProviderListSortMode: String, CaseIterable, Sendable {
    case custom
    case alphabetical
    case family

    public static func resolved(rawValue: String?, alphabetical: Bool) -> Self {
        if let mode = rawValue.flatMap(Self.init(rawValue:)), mode == .family {
            return .family
        }
        return alphabetical ? .alphabetical : .custom
    }
}

/// A browsing relationship, never a shared credential, account, or quota boundary.
public struct ProviderFamily: Hashable, Sendable {
    public let id: String
    public let name: String
    public let searchAliases: [String]

    public static let openAI = Self(id: "company-openai", name: "OpenAI", searchAliases: [])
    public static let google = Self(id: "company-google", name: "Google", searchAliases: ["谷歌"])
    public static let aws = Self(id: "company-aws", name: "AWS", searchAliases: ["Amazon", "亚马逊", "亞馬遜"])
    public static let moonshotServices = Self(
        id: "company-moonshot", name: "Kimi / Moonshot", searchAliases: ["月之暗面"])
    public static let openCode = Self(id: "company-opencode", name: "OpenCode", searchAliases: [])
    public static let alibabaServices = Self(
        id: "company-alibaba", name: "Alibaba / Qwen", searchAliases: ["阿里云", "阿里雲", "通义", "通義"])
    public static let vercelServices = Self(id: "company-vercel", name: "Vercel", searchAliases: [])
    public static let xaiServices = Self(id: "company-xai", name: "Grok / xAI", searchAliases: [])
}

public struct ProviderCatalogPresentation: Sendable {
    public var family: ProviderFamily?
    public var searchAliases: [String]

    public init(family: ProviderFamily? = nil, searchAliases: [String] = []) {
        self.family = family
        self.searchAliases = searchAliases
    }
}

public enum ProviderBrowserCatalog {
    public struct Filter: Sendable {
        public let query: String
        public let enabledOnly: Bool

        public init(query: String = "", enabledOnly: Bool = false) {
            self.query = query
            self.enabledOnly = enabledOnly
        }
    }

    public struct Section: Identifiable, Sendable {
        public let id: String
        public let title: String?
        public let providers: [UsageProvider]
    }

    public static func matches(
        _ provider: UsageProvider,
        query: String,
        displayName: String) -> Bool
    {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let family = descriptor.catalog.family
        let fields = [displayName, descriptor.metadata.shortDisplayName, provider.rawValue, descriptor.cli.name]
            + descriptor.cli.aliases + descriptor.catalog.searchAliases
            + (family.map { [$0.name, $0.id] + $0.searchAliases } ?? [])
        return words.allSatisfy { word in
            fields.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    public static func sections(
        providers: [UsageProvider],
        mode: ProviderListSortMode,
        enabled: Set<UsageProvider>,
        filter: Filter,
        displayName: (UsageProvider) -> String) -> [Section]
    {
        let filtered = providers.filter {
            (!filter.enabledOnly || enabled.contains($0))
                && self.matches($0, query: filter.query, displayName: displayName($0))
        }
        guard !filtered.isEmpty else { return [] }
        if mode != .family {
            let ordered = mode == .custom ? filtered : filtered.sorted { lhs, rhs in
                if enabled.contains(lhs) != enabled.contains(rhs) { return enabled.contains(lhs) }
                return self.namePrecedes(displayName(lhs), displayName(rhs), lhs.rawValue, rhs.rawValue)
            }
            return [Section(id: "all", title: nil, providers: ordered)]
        }

        func sectionID(_ provider: UsageProvider) -> String {
            ProviderDescriptorRegistry.descriptor(for: provider).catalog.family
                .map { "family:\($0.id)" } ?? "provider:\(provider.rawValue)"
        }
        let totals = Dictionary(grouping: providers, by: sectionID)
        let groups = Dictionary(grouping: filtered, by: sectionID)
        let sections = groups.map { id, members in
            let family = ProviderDescriptorRegistry.descriptor(for: members[0]).catalog.family
            return Section(
                id: id,
                title: (totals[id]?.count ?? 0) > 1 ? family?.name : nil,
                providers: members.sorted {
                    self.namePrecedes(displayName($0), displayName($1), $0.rawValue, $1.rawValue)
                })
        }
        return sections.sorted { lhs, rhs in
            let lhsName = lhs.title ?? displayName(lhs.providers[0])
            let rhsName = rhs.title ?? displayName(rhs.providers[0])
            return self.namePrecedes(lhsName, rhsName, lhs.id, rhs.id)
        }
    }

    private static func namePrecedes(_ lhs: String, _ rhs: String, _ lhsID: String, _ rhsID: String) -> Bool {
        switch lhs.localizedCaseInsensitiveCompare(rhs) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhsID < rhsID
        }
    }
}

public enum ProviderOrderMutation {
    /// Replace only the displayed providers' slots, retaining every hidden provider and its position.
    public static func merging(
        visibleOrder: [ProviderInstanceID],
        into fullOrder: [ProviderInstanceID]) -> [ProviderInstanceID]?
    {
        let visible = Set(visibleOrder)
        guard visible.count == visibleOrder.count,
              Set(fullOrder).count == fullOrder.count,
              fullOrder.filter({ visible.contains($0) }).count == visibleOrder.count
        else { return nil }
        var index = 0
        return fullOrder.map { id in
            guard visible.contains(id) else { return id }
            defer { index += 1 }
            return visibleOrder[index]
        }
    }

    public static func moving(
        visibleOrder: [ProviderInstanceID],
        fromOffsets: IndexSet,
        toOffset: Int,
        in fullOrder: [ProviderInstanceID]) -> [ProviderInstanceID]?
    {
        let visible = Set(visibleOrder)
        guard !fromOffsets.isEmpty,
              fromOffsets.allSatisfy({ visibleOrder.indices.contains($0) }),
              (0...visibleOrder.count).contains(toOffset),
              fullOrder.filter({ visible.contains($0) }) == visibleOrder
        else { return nil }
        let moved = fromOffsets.map { visibleOrder[$0] }
        var result = visibleOrder.enumerated().filter { !fromOffsets.contains($0.offset) }.map(\.element)
        let destination = toOffset - fromOffsets.count(where: { $0 < toOffset })
        result.insert(contentsOf: moved, at: destination)
        return self.merging(visibleOrder: result, into: fullOrder)
    }
}
