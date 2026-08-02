import CodexBarCore
import SwiftUI

struct OverviewQuotaRow: Equatable, Identifiable {
    let provider: UsageProvider
    let displayName: String
    let remainingPercent: Double?
    let usedPercent: Double?
    let percentLabel: String
    let hasError: Bool
    let errorText: String?
    let resetText: String?
    let progressColor: Color

    var id: String {
        self.provider.rawValue
    }

    var isExhausted: Bool {
        !self.hasError && self.remainingPercent == 0
    }
}

struct OverviewUnifiedModel: Equatable {
    let totals: OverviewTotalsModel?
    let quotaRows: [OverviewQuotaRow]
    let resetLines: [String]

    var heightFingerprint: String {
        let rows = self.quotaRows.map { row in
            [
                row.provider.rawValue,
                row.remainingPercent.map { String($0) } ?? "-",
                row.hasError ? (row.errorText ?? "error") : "ok",
            ].joined(separator: "|")
        }
        return [
            "overviewUnified",
            self.totals?.heightFingerprint ?? "-",
            rows.joined(separator: ";"),
            self.resetLines.joined(separator: ";"),
        ].joined(separator: ":")
    }
}

/// One-card Overview: totals plus every enabled provider's live quota in a two-column
/// chip grid. Each provider appears exactly once; the only extra line is upcoming reset
/// info. Per-provider details stay one drill-in away (submenu or provider switcher).
struct OverviewUnifiedCardView: View {
    let model: OverviewUnifiedModel
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let totals = self.model.totals {
                self.totalsHeader(totals)
            }
            if !self.model.quotaRows.isEmpty {
                self.quotaGrid
            }
            if !self.model.resetLines.isEmpty {
                Text(self.model.resetLines.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(self.resetLineColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.vertical, 8)
        .frame(width: self.width, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.accessibilityText)
    }

    private func totalsHeader(_ totals: OverviewTotalsModel) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L("overview_totals_title"))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Text(self.costSummary(totals))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let detail = self.totalsDetail(totals) {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var quotaGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: 8, alignment: .leading),
            GridItem(.flexible(), spacing: 8, alignment: .leading),
        ]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(self.model.quotaRows) { row in
                self.chip(row)
            }
        }
    }

    private func costSummary(_ totals: OverviewTotalsModel) -> String {
        let priced = totals.groups.compactMap { group -> String? in
            guard let cost = group.totalCost else { return nil }
            return UsageFormatter.currencyString(cost, currencyCode: group.currencyCode)
        }
        return priced.isEmpty ? L("overview_totals_unpriced") : priced.joined(separator: " · ")
    }

    private func totalsDetail(_ totals: OverviewTotalsModel) -> String? {
        var parts: [String] = []
        if let tokens = totals.totalTokens {
            parts.append("\(UsageFormatter.tokenCountString(tokens)) \(L("tokens"))")
        }
        parts.append(spendDashboardDayRangeText(totals.coveredDayCount))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func chip(_ row: OverviewQuotaRow) -> some View {
        if row.hasError, row.remainingPercent == nil {
            self.errorChip(row)
        } else {
            self.quotaChip(row)
        }
    }

    private func quotaChip(_ row: OverviewQuotaRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(self.dotColor(row))
                    .frame(width: 6, height: 6)
                Text(row.displayName)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(row.percentLabel)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(self.percentColor(row))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            self.miniBar(row)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.displayName) \(row.percentLabel)")
    }

    private func errorChip(_ row: OverviewQuotaRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(self.errorColor)
                Text(row.displayName)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(self.errorColor)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            Text(row.errorText ?? "")
                .font(.footnote)
                .foregroundStyle(self.errorColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.displayName) \(row.errorText ?? "")")
    }

    private func miniBar(_ row: OverviewQuotaRow) -> some View {
        let fraction = (row.remainingPercent ?? 0) / 100
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(MenuHighlightStyle.progressTrack(self.isHighlighted))
                Capsule()
                    .fill(self.dotColor(row))
                    .frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 4)
        .frame(maxWidth: .infinity)
    }

    private var errorColor: Color {
        guard !self.isHighlighted else { return MenuHighlightStyle.selectionText }
        return MenuHighlightStyle.error(false)
    }

    private var resetLineColor: Color {
        guard !self.isHighlighted else { return MenuHighlightStyle.selectionText }
        return Color(nsColor: .systemOrange)
    }

    private func dotColor(_ row: OverviewQuotaRow) -> Color {
        guard !self.isHighlighted else { return MenuHighlightStyle.selectionText }
        if row.hasError {
            return MenuHighlightStyle.error(false)
        }
        if row.isExhausted {
            return Color(nsColor: .systemRed)
        }
        return row.progressColor
    }

    private func percentColor(_ row: OverviewQuotaRow) -> Color {
        guard !self.isHighlighted else { return MenuHighlightStyle.selectionText }
        if row.hasError || row.isExhausted {
            return Color(nsColor: .systemRed)
        }
        return MenuHighlightStyle.secondary(false)
    }

    private var accessibilityText: String {
        var parts = [L("overview_totals_title")]
        parts.append(contentsOf: self.model.quotaRows.map {
            $0.hasError ? "\($0.displayName) \($0.errorText ?? "")" : "\($0.displayName) \($0.percentLabel)"
        })
        parts.append(contentsOf: self.model.resetLines)
        return parts.joined(separator: ", ")
    }
}
