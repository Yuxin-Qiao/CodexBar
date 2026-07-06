import SwiftUI

extension ProviderStatusIndicator {
    /// Traffic-light color used for the per-component dot in the status submenu.
    var dotColor: Color {
        switch self {
        case .none: Color(red: 0.20, green: 0.78, blue: 0.35)
        case .minor, .maintenance: Color(red: 0.96, green: 0.77, blue: 0.13)
        case .major, .critical: Color(red: 0.91, green: 0.30, blue: 0.24)
        case .unknown: Color.secondary
        }
    }
}

/// Renders the list of statuspage.io component rows inside the provider's status submenu.
/// Each leaf row is: colored dot (far left) · service name · right-aligned status text.
/// A component group renders as an expandable dropdown: the parent shows the group's own
/// status, and a chevron reveals the individual child statuses indented beneath it
/// (modeled on the "Other" disclosure in StorageBreakdownMenuView).
struct StatusComponentsMenuView: View {
    let components: [ProviderStatusComponent]
    let width: CGFloat
    /// Invoked after a group expands or collapses so the host can re-measure the row height.
    let onToggle: (() -> Void)?

    @State private var expandedGroupIDs: Set<String> = []

    init(
        components: [ProviderStatusComponent],
        width: CGFloat,
        onToggle: (() -> Void)? = nil)
    {
        self.components = components
        self.width = width
        self.onToggle = onToggle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(self.components) { component in
                if component.isGroup {
                    self.groupRow(component)
                } else {
                    self.statusRow(component)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A single leaf row: dot · name · right-aligned status.
    private func statusRow(_ component: ProviderStatusComponent, indented: Bool = false) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(component.indicator.dotColor)
                .frame(width: 8, height: 8)
            Text(component.name)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 16)
            Text(component.statusLabel)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.leading, indented ? 17 : 0)
    }

    /// An expandable group: parent status row with a chevron, revealing children when expanded.
    private func groupRow(_ group: ProviderStatusComponent) -> some View {
        let isExpanded = self.expandedGroupIDs.contains(group.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if isExpanded {
                    self.expandedGroupIDs.remove(group.id)
                } else {
                    self.expandedGroupIDs.insert(group.id)
                }
                self.onToggle?()
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(group.indicator.dotColor)
                        .frame(width: 8, height: 8)
                    Text(group.name)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 16)
                    Text(group.statusLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(group.children) { child in
                        self.statusRow(child, indented: true)
                    }
                }
            }
        }
    }
}

extension StatusUptimeDaySeverity {
    fileprivate var barColor: Color { switch self {
        case .operational: Color(red: 0.20, green: 0.78, blue: 0.35)
        case .degraded: Color(red: 0.96, green: 0.77, blue: 0.13)
        case .partialOutage: Color(red: 0.98, green: 0.55, blue: 0.18)
        case .majorOutage: Color(red: 0.91, green: 0.30, blue: 0.24) } }
}

struct StatusComponentsUptimeMenuView: View {
    let components: [ProviderStatusComponent]
    let uptimeByComponentID: [String: StatusComponentUptime]
    let width: CGFloat
    let onToggle: (() -> Void)?
    @State private var expandedGroupIDs: Set<String> = []
    init(components: [ProviderStatusComponent], uptimeByComponentID: [String: StatusComponentUptime], width: CGFloat, onToggle: (() -> Void)? = nil) {
        self.components = components; self.uptimeByComponentID = uptimeByComponentID; self.width = width; self.onToggle = onToggle
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { ForEach(components) { c in if c.isGroup { groupSection(c) } else { componentSection(c) } } }
            .padding(.horizontal, 14).padding(.vertical, 8).frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
    private func componentSection(_ c: ProviderStatusComponent, indented: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow(c, indented: indented)
            if let u = uptimeByComponentID[c.id] { uptimeBars(u) }
        }
    }
    private func groupSection(_ g: ProviderStatusComponent) -> some View {
        let open = expandedGroupIDs.contains(g.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if open {
                    self.expandedGroupIDs.remove(g.id)
                } else {
                    self.expandedGroupIDs.insert(g.id)
                }
                self.onToggle?()
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(g.indicator.dotColor).frame(width: 8, height: 8)
                    Text(g.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: 8); Text(g.statusLabel).font(.system(size: 12)).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open { VStack(alignment: .leading, spacing: 10) { ForEach(g.children) { componentSection($0, indented: true) } } }
        }
    }
    private func headerRow(_ c: ProviderStatusComponent, indented: Bool) -> some View {
        HStack(spacing: 8) {
            Circle().fill(c.indicator.dotColor).frame(width: 8, height: 8)
            Text(c.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            if let u = uptimeByComponentID[c.id] {
                Text(String(format: L("status_uptime_percent_format"), u.uptimePercent)).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            } else { Text(c.statusLabel).font(.system(size: 12)).foregroundStyle(.secondary) }
        }.padding(.leading, indented ? 17 : 0)
    }
    private func uptimeBars(_ u: StatusComponentUptime) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) { ForEach(u.days) { d in RoundedRectangle(cornerRadius: 1.5).fill(d.severity.barColor).frame(width: 4, height: 22) } }
            Text(L("status_uptime_past_30_days")).font(.system(size: 10)).foregroundStyle(.tertiary)
        }.padding(.leading, 16)
    }
}
