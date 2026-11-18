import SwiftUI
import AgentQuotaCore

enum PopoverResetLayout: String, CaseIterable, Identifiable {
    case providerColumns
    case periodLists

    var id: String { rawValue }

    var title: String {
        L10n.string("settings.reset_layout.\(rawValue)")
    }
}

/// Displays the local reset time for each tracked limit.
struct UsageResetView: View {
    let summaries: [ProviderUsageSummary]
    let statuses: [ProviderID: ProviderConnectionStatus]
    let loadingProviders: Set<ProviderID>
    let layout: PopoverResetLayout
    let now: Date

    var body: some View {
        switch layout {
        case .providerColumns:
            HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
                ForEach(summaries) { providerCard($0) }
            }
            .fixedSize(horizontal: false, vertical: true)
        case .periodLists:
            periodLists
        }
    }

    private func providerCard(_ summary: ProviderUsageSummary) -> some View {
        let color = DesignTokens.Colors.provider(summary.provider)
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            providerLabel(summary)
            if hasLimits(summary) {
                ForEach(UsageSlot.allCases) { slot in
                    providerPeriod(summary, slot: slot)
                }
            } else {
                emptyState(summary.provider)
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DesignTokens.Colors.cardBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(color)
                .frame(height: DesignTokens.Stroke.resetCardAccentWidth)
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
    }

    private func providerPeriod(_ summary: ProviderUsageSummary, slot: UsageSlot) -> some View {
        let window = summary.window(for: slot)
        let time = L10n.resetClock(until: window?.resetsAt, now: now)
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Divider()
            HStack(spacing: DesignTokens.Spacing.xxs) {
                if window != nil {
                    periodMarker(slot, color: DesignTokens.Colors.provider(summary.provider))
                }
                periodTitle(limitTitle(slot, window: window))
            }
            resetMoment(time, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(window.map { L10n.resetInText(until: $0.resetsAt, now: now) } ?? "")
    }

    private var periodLists: some View {
        Grid(alignment: .leading, horizontalSpacing: DesignTokens.Spacing.xs, verticalSpacing: DesignTokens.Spacing.xs) {
            GridRow {
                ForEach(UsageSlot.allCases) { slot in
                    HStack(spacing: DesignTokens.Spacing.xxs) {
                        periodMarker(slot, color: DesignTokens.Colors.legendMarker)
                        periodTitle(columnTitle(slot))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.top, .horizontal], DesignTokens.Spacing.sm)
                }
            }
            ForEach(summaries) { summary in
                GridRow(alignment: .top) {
                    ForEach(UsageSlot.allCases) { slot in
                        periodListEntry(summary, slot: slot)
                    }
                }
            }
        }
        .padding(.bottom, DesignTokens.Spacing.sm)
        .background {
            HStack(spacing: DesignTokens.Spacing.xs) {
                ForEach(UsageSlot.allCases) { _ in
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                        .fill(DesignTokens.Colors.cardBackground)
                }
            }
        }
    }

    private func periodListEntry(_ summary: ProviderUsageSummary, slot: UsageSlot) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Divider()
            HStack(spacing: DesignTokens.Spacing.xxs) {
                providerLabel(summary)
                Spacer(minLength: 0)
                if hasLimits(summary) {
                    let time = L10n.resetClock(until: summary.window(for: slot)?.resetsAt, now: now)
                    resetMoment(time, alignment: .trailing, compact: true)
                        .frame(width: DesignTokens.Layout.resetListTimeWidth, alignment: .trailing)
                } else {
                    emptyState(summary.provider)
                        .frame(maxWidth: DesignTokens.Layout.resetListTimeWidth, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
    }

    private func providerLabel(_ summary: ProviderUsageSummary) -> some View {
        let provider = summary.provider
        let status = statuses[provider] ?? .unknown
        return HStack(spacing: DesignTokens.Spacing.xxs) {
            ProviderIconView(provider: provider, size: DesignTokens.Layout.resetProviderIconSize)
            Text(provider.displayName)
                .font(.system(size: DesignTokens.Typography.captionSize, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)

            if hasLimits(summary) {
                if loadingProviders.contains(provider) {
                    ProgressView().controlSize(.mini)
                } else if !status.isHealthy && status != .unknown {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: DesignTokens.Layout.iconSmallSize))
                        .foregroundStyle(DesignTokens.Colors.statusWarning)
                        .help(L10n.statusText(status, provider: provider, now: now))
                }
            }
        }
    }

    @ViewBuilder
    private func emptyState(_ provider: ProviderID) -> some View {
        let status = statuses[provider] ?? .unknown
        if loadingProviders.contains(provider) {
            ProgressView().controlSize(.small)
        } else if !status.isHealthy {
            Text(L10n.statusText(status, provider: provider, now: now))
                .font(.system(size: DesignTokens.Typography.captionSize))
                .foregroundStyle(DesignTokens.Colors.statusWarning)
                .lineLimit(2)
                .help(L10n.statusText(status, provider: provider, now: now))
        } else {
            Text(L10n.string("popover.no_visible_limits_short"))
                .font(.system(size: DesignTokens.Typography.captionSize))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
    }

    private func resetMoment(
        _ reset: (day: String?, time: String),
        alignment: HorizontalAlignment,
        compact: Bool = false
    ) -> some View {
        let clockSize = compact ? DesignTokens.Typography.captionSize : DesignTokens.Typography.resetTimeSize
        return VStack(alignment: alignment, spacing: DesignTokens.Spacing.xxxs) {
            if let day = reset.day {
                Text(day)
                    .font(.system(size: DesignTokens.Typography.microSize))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
            }
            Text(reset.time)
                .font(.system(size: clockSize, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func periodTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: DesignTokens.Typography.captionSize, weight: .semibold))
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

    private func periodMarker(_ slot: UsageSlot, color: Color) -> some View {
        Group {
            switch slot {
            case .short:
                Circle().strokeBorder(color, lineWidth: DesignTokens.Stroke.legendRingWidth)
            case .weekly:
                Circle().fill(color)
            }
        }
        .frame(width: DesignTokens.Layout.resetMarkerSize, height: DesignTokens.Layout.resetMarkerSize)
        .accessibilityHidden(true)
    }

    private func hasLimits(_ summary: ProviderUsageSummary) -> Bool {
        summary.short != nil || summary.weekly != nil
    }

    private func limitTitle(_ slot: UsageSlot, window: QuotaWindow?) -> String {
        if slot == .weekly { return L10n.string("popover.limit.weekly") }
        guard let window, window.cadence != .fiveHour else {
            return L10n.string("popover.limit.five_hour")
        }
        let isDaily = window.windowDurationSeconds == QuotaCadence.other.durationSeconds
        return L10n.string(isDaily ? "popover.limit.daily" : "popover.limit.short")
    }

    private func columnTitle(_ slot: UsageSlot) -> String {
        let windows = summaries.compactMap { $0.window(for: slot) }
        let first = limitTitle(slot, window: windows.first)
        if windows.allSatisfy({ limitTitle(slot, window: $0) == first }) {
            return first
        }
        if windows.allSatisfy({ $0.cadence == .fiveHour || $0.windowDurationSeconds == QuotaCadence.other.durationSeconds }) {
            return L10n.string("popover.limit.five_hour_and_daily")
        }
        return L10n.string("popover.limit.short")
    }
}
