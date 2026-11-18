import SwiftUI
import AgentQuotaCore

/// Popover chart viewer. Persisted by raw value, so keep the cases' raw values stable.
enum PopoverChartLayout: String, CaseIterable, Identifiable {
    /// One small pace plot per provider (default).
    case byProvider
    /// One pace plot per window slot (5-hour/daily and weekly) with every provider on it.
    case byWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .byProvider: return L10n.string("settings.chart_layout.by_provider")
        case .byWindow: return L10n.string("settings.chart_layout.by_window")
        }
    }
}

/// Pace plots in the selected layout plus the marker legend.
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
    }

    // MARK: - Layouts

    private var providerCharts: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            ForEach(summaries) { summary in
                PacePlotView(markers: UsageSlot.allCases.compactMap { slot in
                    marker(for: summary, slot: slot)
                })
            }
        }
    }

    private var windowCharts: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            ForEach(UsageSlot.allCases) { slot in
                PacePlotView(markers: summaries.compactMap { summary in
                    marker(for: summary, slot: slot)
                })
            }
        }
    }

    private var legend: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Circle()
                .strokeBorder(DesignTokens.Colors.legendMarker, lineWidth: DesignTokens.Stroke.legendRingWidth)
                .frame(width: DesignTokens.Layout.legendMarkerSize, height: DesignTokens.Layout.legendMarkerSize)
            Text(L10n.slotTitle(.short))
            Circle()
                .fill(DesignTokens.Colors.legendMarker)
                .frame(width: DesignTokens.Layout.legendMarkerSize, height: DesignTokens.Layout.legendMarkerSize)
                .padding(.leading, DesignTokens.Spacing.xs)
            Text(L10n.slotTitle(.weekly))
        }
        .font(.system(size: DesignTokens.Typography.captionSize, weight: .medium))
        .foregroundStyle(DesignTokens.Colors.textSecondary)
    }

    // MARK: - Markers

    private func marker(for summary: ProviderUsageSummary, slot: UsageSlot) -> PacePlotMarker? {
        guard let window = summary.window(for: slot), let elapsed = window.elapsedFraction(at: now) else {
            return nil
        }
        let percent = "\(Int(window.usedPercent.rounded()))%"
        return PacePlotMarker(
            id: "\(summary.provider.rawValue).\(slot.rawValue)",
            x: elapsed,
            y: window.usedPercent / 100,
            color: DesignTokens.Colors.provider(summary.provider),
            style: slot == .weekly ? .filled : .ring,
            label: percent,
            help: L10n.format(
                "popover.marker_help",
                summary.provider.displayName,
                L10n.slotTitle(slot),
                percent,
                L10n.resetClockText(until: window.resetsAt, now: now)
            )
        )
    }
}
