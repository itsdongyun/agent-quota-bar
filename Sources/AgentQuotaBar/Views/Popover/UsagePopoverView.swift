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
        .onAppear { store.popoverDidOpen() }
    }

    // MARK: - Header

    private func headerBar(now: Date) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            resetAnnouncementBadges(now: now)
            Spacer()
            Button {
                Task { await store.userRefresh() }
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
            ForEach(ProviderID.allCases) { provider in
                if store.settings.preferences(for: provider).isEnabled {
                    // A reset seen in our own usage data is the same event a tracker reports later, and more certain.
                    if let detected = store.detectedResets[provider], detected.isActive(at: now) {
                        detectedResetBadge(detected)
                    } else if let announcement = store.resetAnnouncements[provider], announcement.isActive(at: now) {
                        resetAnnouncementBadge(announcement, now: now)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func resetAnnouncementBadge(_ announcement: ResetAnnouncement, now: Date) -> some View {
        let title = badgeTitle(for: announcement.kind)
        let helpText = badgeHelpText(for: announcement, now: now)

        if let url = announcement.sourceURL {
            Link(destination: url) {
                resetBadge(for: announcement.provider, title: title)
            }
            .buttonStyle(.plain)
            .help(helpText)
        } else {
            resetBadge(for: announcement.provider, title: title)
                .help(helpText)
        }
    }

    private func detectedResetBadge(_ detected: DetectedReset) -> some View {
        let windows = detected.windows.map { L10n.localizedWindowLabel($0) }.joined(separator: ", ")
        let time = detected.detectedAt.formatted(date: .omitted, time: .shortened)
        return resetBadge(for: detected.provider, title: L10n.string("popover.detected_reset_badge"))
            .help(L10n.format("popover.detected_reset_at", detected.provider.displayName, windows, time))
    }

    private func badgeTitle(for kind: ResetAnnouncement.Kind) -> String {
        switch kind {
        case .watch:
            return L10n.string("popover.reset_badge")
        case .bankedReset:
            return L10n.string("popover.banked_reset_badge")
        case .recentReset:
            return L10n.string("popover.recent_reset_badge")
        }
    }

    private func badgeHelpText(for announcement: ResetAnnouncement, now: Date) -> String {
        let providerName = announcement.provider.displayName
        switch announcement.kind {
        case .watch:
            return (announcement.targetAt.map { L10n.countdownText(until: $0, now: now) } ?? announcement.windowLabel)
                .map { L10n.format("popover.reset_target", $0) }
                ?? L10n.format("popover.reset_watch_fallback", providerName)
        case .bankedReset:
            if let expiresAt = announcement.expiresAt {
                return L10n.format(
                    "popover.banked_reset_expires",
                    providerName,
                    L10n.resetClockText(until: expiresAt, now: now)
                )
            }
            return L10n.format("popover.banked_reset_fallback", providerName)
        case .recentReset:
            if let announcedAt = announcement.announcedAt {
                let formattedTime = announcedAt.formatted(date: .abbreviated, time: .shortened)
                return L10n.format("popover.recent_reset_at", providerName, formattedTime)
            }
            return L10n.format("popover.recent_reset_fallback", providerName)
        }
    }

    private func resetBadge(for provider: ProviderID, title: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.xxs) {
            ProviderIconView(
                provider: provider,
                size: DesignTokens.Layout.iconSmallSize,
                tintColor: DesignTokens.Colors.provider(provider)
            )
            Text(title)
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
        .accessibilityLabel("\(provider.displayName) \(title)")
    }
}
