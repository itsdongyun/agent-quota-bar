import AppKit
import SwiftUI
import AgentQuotaCore

/// Main popover with refresh and menu actions, pace charts, and per-provider reset information.
struct UsagePopoverView: View {
    @Bindable var store: QuotaStore
    let chartLayout: PopoverChartLayout
    let resetLayout: PopoverResetLayout
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let summaries = store.usageSummaries()

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                headerBar(now: now)

                if summaries.isEmpty {
                    Text(L10n.string("popover.no_visible_limits"))
                        .font(.system(size: DesignTokens.Typography.captionSize))
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, DesignTokens.Spacing.lg)
                } else {
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

    private func headerBar(now: Date) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            resetAnnouncementBadges(now: now)
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

    private func resetAnnouncementBadges(now: Date) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            if store.settings.preferences(for: .codex).isEnabled,
               let announcement = store.codexResetAnnouncement,
               announcement.isActive(at: now)
            {
                codexResetBadge(announcement, now: now)
            }
        }
    }

    @ViewBuilder
    private func codexResetBadge(_ announcement: CodexResetAnnouncement, now: Date) -> some View {
        let helpText = (announcement.targetAt.map { L10n.countdownText(until: $0, now: now) } ?? announcement.windowLabel)
            .map { L10n.format("popover.codex_reset_target", $0) }
            ?? L10n.string("popover.codex_reset_badge")

        if let url = announcement.sourceURL {
            Link(destination: url) {
                resetBadge(for: .codex)
            }
            .buttonStyle(.plain)
            .help(helpText)
        } else {
            resetBadge(for: .codex)
                .help(helpText)
        }
    }

    private func resetBadge(for provider: ProviderID) -> some View {
        HStack(spacing: DesignTokens.Spacing.xxs) {
            ProviderIconView(
                provider: provider,
                size: DesignTokens.Layout.iconSmallSize,
                tintColor: DesignTokens.Colors.provider(provider)
            )
            Text(L10n.string("popover.reset_badge"))
                .font(.system(size: DesignTokens.Typography.microSize, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(DesignTokens.Colors.provider(provider))
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xxs)
        .background(DesignTokens.Colors.resetBadgeBackground(provider))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.pill))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.pill)
                .stroke(DesignTokens.Colors.resetBadgeBorder(provider), lineWidth: DesignTokens.Stroke.hairline)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(provider.displayName) \(L10n.string("popover.reset_badge"))")
    }
}
