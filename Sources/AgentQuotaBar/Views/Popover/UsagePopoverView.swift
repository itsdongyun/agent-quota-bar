import AppKit
import SwiftUI
import AgentQuotaCore

/// Main popover with refresh and menu actions, pace charts, and per-provider reset information.
struct UsagePopoverView: View {
    @Bindable var store: QuotaStore
    let chartLayout: PopoverChartLayout
    let resetLayout: PopoverResetLayout
    var isMockMode = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let summaries = store.usageSummaries()

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                headerBar

                if summaries.isEmpty {
                    Text(L10n.string("popover.no_visible_limits"))
                        .font(.system(size: DesignTokens.Typography.captionSize))
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, DesignTokens.Spacing.lg)
                } else {
                    if store.settings.preferences(for: .codex).isEnabled,
                       let announcement = store.codexResetAnnouncement,
                       announcement.isActive(at: now)
                    {
                        codexResetBanner(announcement, now: now)
                    }

                    UsageChartCardView(summaries: summaries, layout: chartLayout, now: now)

                    UsageResetView(
                        summaries: summaries,
                        statuses: store.connectionStatuses,
                        loadingProviders: store.refreshingProviders,
                        layout: resetLayout,
                        now: now
                    )
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
            Spacer()
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
                        openDesktopWindow(id: "mock-data")
                    }
                }
                Button(L10n.string("action.settings")) {
                    openDesktopWindow(id: "settings")
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

    private func openDesktopWindow(id: String) {
        DesktopWindowPresence.prepareToOpen()
        openWindow(id: id)
        NSApp.activate()
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
