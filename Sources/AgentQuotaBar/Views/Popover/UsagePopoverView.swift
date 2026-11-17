import AppKit
import SwiftUI
import AgentQuotaCore

/// Main popover: header with viewer toggle, provider filter chips, pace chart card, and usage table.
struct UsagePopoverView: View {
    @Bindable var store: QuotaStore
    var isMockMode = false
    @Environment(\.openWindow) private var openWindow
    @AppStorage("AgentQuotaBar.PopoverChartLayout") private var chartLayout: PopoverChartLayout = .byProvider
    /// `nil` shows every enabled provider.
    @State private var providerFilter: ProviderID?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let summaries = store.usageSummaries()
            let activeFilter = providerFilter.flatMap { filter in
                summaries.contains { $0.provider == filter } ? filter : nil
            }
            let shown = activeFilter.map { filter in summaries.filter { $0.provider == filter } } ?? summaries

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                headerBar

                if summaries.isEmpty {
                    Text(L10n.string("popover.no_visible_limits"))
                        .font(.system(size: DesignTokens.Typography.captionSize))
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, DesignTokens.Spacing.lg)
                } else {
                    filterChips(summaries.map(\.provider), active: activeFilter)

                    if store.settings.preferences(for: .codex).isEnabled,
                       let announcement = store.codexResetAnnouncement,
                       announcement.isActive(at: now)
                    {
                        codexResetBanner(announcement, now: now)
                    }

                    UsageChartCardView(summaries: shown, layout: chartLayout, now: now)

                    UsageTableView(
                        summaries: shown,
                        statuses: store.connectionStatuses,
                        loadingProviders: store.refreshingProviders,
                        now: now
                    )
                    .padding(.horizontal, DesignTokens.Spacing.xxs)
                }
            }
            .padding(DesignTokens.Spacing.lg)
            .frame(width: DesignTokens.Layout.popoverWidth)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(L10n.string("popover.title"))
                .font(.system(size: DesignTokens.Typography.popoverTitleSize, weight: .bold))
                .foregroundStyle(DesignTokens.Colors.textPrimary)
            Spacer()
            layoutPicker
            Button {
                Task { await store.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: DesignTokens.Layout.iconMediumSize, weight: .semibold))
                    .frame(width: DesignTokens.Layout.headerButtonSize, height: DesignTokens.Layout.headerButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .disabled(store.isRefreshing)
            .help(updatedLabel)

            Menu {
                Text(updatedLabel)
                Divider()
                if isMockMode {
                    Button(L10n.string("mock.menu_item")) {
                        openWindow(id: "mock-data")
                        NSApp.activate()
                    }
                }
                Button(L10n.string("action.settings")) {
                    openWindow(id: "settings")
                    NSApp.activate()
                }
                Button(L10n.string("action.quit")) {
                    NSApp.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: DesignTokens.Layout.iconMediumSize, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: DesignTokens.Layout.headerButtonSize, height: DesignTokens.Layout.headerButtonSize)
            .help(L10n.string("action.more"))
        }
    }

    private var layoutPicker: some View {
        HStack(spacing: DesignTokens.Spacing.xxxs) {
            ForEach(PopoverChartLayout.allCases) { option in
                let isSelected = option == chartLayout
                Button {
                    chartLayout = option
                } label: {
                    Image(systemName: option.symbolName)
                        .font(.system(size: DesignTokens.Layout.iconSmallSize, weight: .semibold))
                        .foregroundStyle(isSelected ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
                        .frame(width: DesignTokens.Layout.segmentButtonWidth, height: DesignTokens.Layout.segmentButtonHeight)
                        .background(isSelected ? DesignTokens.Colors.controlSelectedBackground : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(option.title)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(DesignTokens.Spacing.xxxs)
        .background(DesignTokens.Colors.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
    }

    // MARK: - Filter chips

    private func filterChips(_ providers: [ProviderID], active: ProviderID?) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            chip(title: L10n.string("popover.filter_all"), provider: nil, isSelected: active == nil)
            ForEach(providers) { provider in
                chip(title: provider.displayName, provider: provider, isSelected: active == provider)
            }
        }
    }

    private func chip(title: String, provider: ProviderID?, isSelected: Bool) -> some View {
        Button {
            providerFilter = provider
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                if let provider {
                    Circle()
                        .fill(DesignTokens.Colors.provider(provider))
                        .frame(width: DesignTokens.Layout.providerDotSize, height: DesignTokens.Layout.providerDotSize)
                }
                Text(title)
                    .font(.system(size: DesignTokens.Typography.chipSize, weight: isSelected ? .bold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
            .padding(.horizontal, DesignTokens.Layout.chipHorizontalPadding)
            .padding(.vertical, DesignTokens.Layout.chipVerticalPadding)
            .background(isSelected ? DesignTokens.Colors.controlSelectedBackground : DesignTokens.Colors.controlBackground)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var updatedLabel: String {
        if store.isRefreshing {
            return L10n.string("popover.refreshing")
        }
        guard let lastUpdatedAt = store.lastUpdatedAt else {
            return L10n.string("popover.never_updated")
        }
        return L10n.format(
            "popover.updated_at",
            lastUpdatedAt.formatted(date: .omitted, time: .shortened)
        )
    }

    private func codexResetBanner(_ announcement: CodexResetAnnouncement, now: Date) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "sparkles")
                .font(.system(size: DesignTokens.Layout.iconSmallSize))
                .foregroundStyle(DesignTokens.Colors.textOnBadge)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxxs) {
                Text(L10n.string("popover.codex_reset_badge"))
                    .font(.system(size: DesignTokens.Typography.captionSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textOnBadge)
                if let targetText = announcement.targetAt.map({ L10n.countdownText(until: $0, now: now) }) ?? announcement.windowLabel {
                    Text(L10n.format("popover.codex_reset_target", targetText))
                        .font(.system(size: DesignTokens.Typography.microSize))
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                }
            }
            Spacer()
            if let url = announcement.sourceURL {
                Link(L10n.string("action.open_link"), destination: url)
                    .font(.system(size: DesignTokens.Typography.microSize, weight: .medium))
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .background(DesignTokens.Colors.badgeBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                .stroke(DesignTokens.Colors.badgeBorder, lineWidth: DesignTokens.Stroke.hairline)
        )
    }
}
