import SwiftUI
import AgentQuotaCore

/// Per-provider table of 5-hour/daily and weekly usage with reset times, colored by pace.
struct UsageTableView: View {
    let summaries: [ProviderUsageSummary]
    let statuses: [ProviderID: ProviderConnectionStatus]
    let loadingProviders: Set<ProviderID>
    let now: Date

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: DesignTokens.Spacing.md, verticalSpacing: DesignTokens.Spacing.md) {
            GridRow {
                Color.clear
                    .gridCellUnsizedAxes([.horizontal, .vertical])
                ForEach(UsageSlot.allCases) { slot in
                    Text(L10n.slotTitle(slot))
                        .font(.system(size: DesignTokens.Typography.captionSize, weight: .semibold))
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .gridColumnAlignment(.trailing)
                }
            }

            ForEach(summaries) { summary in
                GridRow {
                    nameCell(summary)
                    if summary.short == nil && summary.weekly == nil {
                        emptyCell(summary.provider)
                            .gridCellColumns(UsageSlot.allCases.count)
                            .gridCellAnchor(.trailing)
                    } else {
                        ForEach(UsageSlot.allCases) { slot in
                            valueCell(summary.window(for: slot), provider: summary.provider, slot: slot)
                        }
                    }
                }
            }
        }
    }

    private func nameCell(_ summary: ProviderUsageSummary) -> some View {
        let status = statuses[summary.provider] ?? .unknown
        let hasData = summary.short != nil || summary.weekly != nil
        return HStack(spacing: DesignTokens.Spacing.sm) {
            Circle()
                .fill(DesignTokens.Colors.provider(summary.provider))
                .frame(width: DesignTokens.Layout.providerDotSize, height: DesignTokens.Layout.providerDotSize)
            Text(summary.provider.displayName)
                .font(.system(size: DesignTokens.Typography.tableNameSize, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)
            if hasData {
                if loadingProviders.contains(summary.provider) {
                    ProgressView()
                        .controlSize(.mini)
                } else if !status.isHealthy && status != .unknown {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: DesignTokens.Layout.iconSmallSize))
                        .foregroundStyle(DesignTokens.Colors.statusWarning)
                        .help(L10n.statusText(status, now: now))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func emptyCell(_ provider: ProviderID) -> some View {
        let status = statuses[provider] ?? .unknown
        if loadingProviders.contains(provider) {
            ProgressView()
                .controlSize(.small)
        } else if !status.isHealthy {
            Text(L10n.statusText(status, now: now))
                .font(.system(size: DesignTokens.Typography.captionSize))
                .foregroundStyle(DesignTokens.Colors.statusWarning)
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: DesignTokens.Layout.tableStatusMaxWidth, alignment: .trailing)
                .help(L10n.statusText(status, now: now))
        } else {
            Text(L10n.string("popover.no_visible_limits_short"))
                .font(.system(size: DesignTokens.Typography.captionSize))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
    }

    private func valueCell(_ window: QuotaWindow?, provider: ProviderID, slot: UsageSlot) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            if let window {
                marker(provider: provider, slot: slot)
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.system(size: DesignTokens.Typography.tablePercentSize, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Colors.paceLevel(UsageSummaryMath.paceLevel(for: window, now: now)))
                    .frame(minWidth: DesignTokens.Layout.tablePercentWidth, alignment: .trailing)
                Text(L10n.resetClockText(until: window.resetsAt, now: now))
                    .font(.system(size: DesignTokens.Typography.tableTimeSize, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .fixedSize()
            } else {
                Text(L10n.string("popover.no_value"))
                    .font(.system(size: DesignTokens.Typography.tableTimeSize))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
        }
        .help(window.map { L10n.resetInText(until: $0.resetsAt, now: now) } ?? "")
    }

    @ViewBuilder
    private func marker(provider: ProviderID, slot: UsageSlot) -> some View {
        switch slot {
        case .weekly:
            Circle()
                .fill(DesignTokens.Colors.provider(provider))
                .frame(width: DesignTokens.Layout.tableMarkerSize, height: DesignTokens.Layout.tableMarkerSize)
        case .short:
            Circle()
                .strokeBorder(DesignTokens.Colors.providerLight(provider), lineWidth: DesignTokens.Stroke.legendRingWidth)
                .frame(width: DesignTokens.Layout.tableMarkerSize, height: DesignTokens.Layout.tableMarkerSize)
        }
    }
}
