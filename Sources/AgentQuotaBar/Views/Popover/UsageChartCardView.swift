import SwiftUI
import AgentQuotaCore

/// Popover chart viewer. Persisted by raw value, so keep the cases' raw values stable.
enum PopoverChartLayout: String, CaseIterable, Identifiable {
    /// One small pace plot per provider (default).
    case byProvider
    /// One pace plot per window slot (5-hour/daily and weekly) with every provider on it.
    case byWindow

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .byProvider: return "square.grid.3x2.fill"
        case .byWindow: return "rectangle.split.2x1"
        }
    }

    var title: String {
        switch self {
        case .byProvider: return L10n.string("popover.layout_by_provider")
        case .byWindow: return L10n.string("popover.layout_by_window")
        }
    }
}

/// Card holding the pace plots in the selected layout plus the marker legend.
struct UsageChartCardView: View {
    let summaries: [ProviderUsageSummary]
    let layout: PopoverChartLayout
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            switch layout {
            case .byProvider:
                providerCharts
            case .byWindow:
                windowCharts
            }
            legend
        }
        .padding(DesignTokens.Spacing.sm)
        .background(DesignTokens.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
    }

    // MARK: - Layouts

    private var providerCharts: some View {
        let isSingle = summaries.count == 1
        return HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
            ForEach(summaries) { summary in
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    HStack(spacing: DesignTokens.Spacing.xxxs) {
                        Circle()
                            .fill(DesignTokens.Colors.provider(summary.provider))
                            .padding(.trailing, DesignTokens.Spacing.xxxs)
                            .frame(width: DesignTokens.Layout.providerDotSize, height: DesignTokens.Layout.providerDotSize)
                        Text(summary.provider.displayName)
                            .font(.system(size: DesignTokens.Typography.chartCardTitleSize, weight: .bold))
                            .foregroundStyle(DesignTokens.Colors.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .layoutPriority(1)
                        Spacer(minLength: DesignTokens.Spacing.xxxs)
                        Text(percentText(summary.weekly))
                            .font(.system(size: DesignTokens.Typography.chartCardTitleSize, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                            .lineLimit(1)
                            .fixedSize()
                    }

                    plot(
                        markers: UsageSlot.allCases.compactMap { slot in
                            marker(for: summary, slot: slot, labeled: isSingle)
                        },
                        height: isSingle
                            ? DesignTokens.Layout.singlePlotHeight
                            : DesignTokens.Layout.providerPlotHeight
                    )
                }
                .padding(DesignTokens.Spacing.xs)
                .frame(maxWidth: .infinity)
                .background(DesignTokens.Colors.nestedCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
            }
        }
    }

    private var windowCharts: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            ForEach(UsageSlot.allCases) { slot in
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text(L10n.slotTitle(slot))
                        .font(.system(size: DesignTokens.Typography.captionSize, weight: .semibold))
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                    plot(
                        markers: summaries.compactMap { summary in
                            marker(for: summary, slot: slot, labeled: true)
                        },
                        height: DesignTokens.Layout.windowPlotHeight
                    )
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Circle()
                .fill(DesignTokens.Colors.legendMarker)
                .frame(width: DesignTokens.Layout.legendMarkerSize, height: DesignTokens.Layout.legendMarkerSize)
            Text(L10n.slotTitle(.weekly))
            Circle()
                .strokeBorder(DesignTokens.Colors.legendMarker, lineWidth: DesignTokens.Stroke.legendRingWidth)
                .frame(width: DesignTokens.Layout.legendMarkerSize, height: DesignTokens.Layout.legendMarkerSize)
                .padding(.leading, DesignTokens.Spacing.xs)
            Text(L10n.slotTitle(.short))
            Spacer()
            DashedLine()
                .stroke(
                    DesignTokens.Colors.chartPaceLine,
                    style: StrokeStyle(
                        lineWidth: DesignTokens.Stroke.paceLineWidth,
                        dash: [DesignTokens.Stroke.paceDashLength, DesignTokens.Stroke.paceDashGap]
                    )
                )
                .frame(width: DesignTokens.Layout.legendDashWidth, height: DesignTokens.Stroke.hairline)
            Text(L10n.string("popover.legend_pace"))
        }
        .font(.system(size: DesignTokens.Typography.captionSize, weight: .medium))
        .foregroundStyle(DesignTokens.Colors.textSecondary)
    }

    /// Fills the available width at a fixed height so the menu bar window can size itself from the content.
    private func plot(markers: [PacePlotMarker], height: CGFloat) -> some View {
        PacePlotView(markers: markers)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }

    // MARK: - Markers

    private func marker(for summary: ProviderUsageSummary, slot: UsageSlot, labeled: Bool) -> PacePlotMarker? {
        guard let window = summary.window(for: slot), let elapsed = window.elapsedFraction(at: now) else {
            return nil
        }
        let percent = percentText(window)
        return PacePlotMarker(
            id: "\(summary.provider.rawValue).\(slot.rawValue)",
            x: elapsed,
            y: window.usedPercent / 100,
            color: slot == .weekly
                ? DesignTokens.Colors.provider(summary.provider)
                : DesignTokens.Colors.providerLight(summary.provider),
            style: slot == .weekly ? .filled : .ring,
            label: labeled ? percent : nil,
            help: L10n.format(
                "popover.marker_help",
                summary.provider.displayName,
                L10n.slotTitle(slot),
                percent,
                L10n.resetClockText(until: window.resetsAt, now: now)
            )
        )
    }

    private func percentText(_ window: QuotaWindow?) -> String {
        guard let window else { return L10n.string("popover.no_value") }
        return "\(Int(window.usedPercent.rounded()))%"
    }
}

private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
