import SwiftUI
import AgentQuotaCore

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case popover
    case providers

    var id: String { rawValue }

    var title: String {
        L10n.string("settings.tab.\(rawValue)")
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .popover: return "macwindow"
        case .providers: return "square.stack.3d.up"
        }
    }
}

/// Tabbed settings window for app behavior, popover layout, and per-provider quota limits.
struct SettingsView: View {
    @Bindable var store: QuotaStore
    @Bindable var launchAtLogin: LaunchAtLoginManager
    @Binding var chartLayout: PopoverChartLayout
    @Binding var resetLayout: PopoverResetLayout

    @State private var selectedTab: SettingsTab = .general
    @State private var selectedProvider: ProviderID = .claude

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.none) {
            tabBar
            Divider()
            tabContent
        }
        .frame(width: DesignTokens.Layout.settingsWidth)
        .frame(minHeight: DesignTokens.Layout.settingsMinHeight)
        .task {
            launchAtLogin.refresh()
            await store.refreshConnectionStatuses()
        }
    }

    // MARK: - Top Tab Bar

    private var tabBar: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            ForEach(SettingsTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: DesignTokens.Spacing.xxs) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: DesignTokens.Layout.settingsTabIconSize, weight: .medium))
                        Text(tab.title)
                            .font(.system(size: DesignTokens.Typography.captionSize, weight: isSelected ? .semibold : .regular))
                    }
                    .foregroundStyle(isSelected ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
                    .frame(minWidth: DesignTokens.Layout.settingsTabMinWidth)
                    .padding(.vertical, DesignTokens.Spacing.xs)
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                            .fill(isSelected ? DesignTokens.Colors.settingsTabSelectedBackground : DesignTokens.Colors.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                            .stroke(
                                isSelected ? DesignTokens.Colors.settingsTabSelectedBorder : DesignTokens.Colors.clear,
                                lineWidth: DesignTokens.Stroke.hairline
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .general:
            generalTab
        case .popover:
            popoverTab
        case .providers:
            providersTab
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section {
                Picker(selection: $store.settings.refreshInterval) {
                    ForEach(RefreshIntervalOption.allCases) { option in
                        Text(L10n.format("settings.interval_minutes", option.minutes))
                            .tag(option)
                    }
                } label: {
                    Label(L10n.string("settings.refresh_interval"), systemImage: "clock")
                }
                .pickerStyle(.menu)

                Toggle(isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )) {
                    Label(L10n.string("settings.launch_at_login"), systemImage: "arrow.up.forward.app")
                }
                .toggleStyle(.switch)
                .disabled(!launchAtLogin.isSupportedInCurrentEnvironment)
            } header: {
                Text(L10n.string("settings.section.behavior"))
            } footer: {
                if !launchAtLogin.isSupportedInCurrentEnvironment {
                    Text(L10n.string("settings.launch_at_login_hint"))
                        .font(.system(size: DesignTokens.Typography.microSize))
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                }
            }
        }
        .formStyle(.grouped)
        .font(.system(size: DesignTokens.Typography.bodySize))
    }

    // MARK: - Popover Tab

    private var popoverTab: some View {
        Form {
            Section {
                Picker(selection: $chartLayout) {
                    ForEach(PopoverChartLayout.allCases) { option in
                        Text(option.title).tag(option)
                    }
                } label: {
                    Label(L10n.string("settings.chart_layout"), systemImage: "chart.xyaxis.line")
                }
                .pickerStyle(.segmented)
            } header: {
                Text(L10n.string("settings.section.charts"))
            } footer: {
                Text(chartLayoutHint)
                    .font(.system(size: DesignTokens.Typography.microSize))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }

            Section {
                Picker(selection: $resetLayout) {
                    ForEach(PopoverResetLayout.allCases) { option in
                        Text(option.title).tag(option)
                    }
                } label: {
                    Label(L10n.string("settings.reset_layout"), systemImage: "rectangle.3.group")
                }
                .pickerStyle(.segmented)
            } header: {
                Text(L10n.string("settings.section.resets"))
            } footer: {
                Text(resetLayoutHint)
                    .font(.system(size: DesignTokens.Typography.microSize))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
        }
        .formStyle(.grouped)
        .font(.system(size: DesignTokens.Typography.bodySize))
    }

    private var chartLayoutHint: String {
        switch chartLayout {
        case .byProvider:
            return L10n.string("settings.chart_layout.by_provider.hint")
        case .byWindow:
            return L10n.string("settings.chart_layout.by_window.hint")
        }
    }

    private var resetLayoutHint: String {
        switch resetLayout {
        case .providerColumns:
            return L10n.string("settings.reset_layout.providerColumns.hint")
        case .periodLists:
            return L10n.string("settings.reset_layout.periodLists.hint")
        }
    }

    // MARK: - Providers Tab

    private var providersTab: some View {
        VStack(spacing: DesignTokens.Spacing.none) {
            providerSelectorHeader
            Divider()
            providerDetailForm(for: selectedProvider)
        }
    }

    private var providerSelectorHeader: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            HStack {
                Text(L10n.string("settings.section.providers"))
                    .font(.system(size: DesignTokens.Typography.sectionHeaderSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                Spacer()
                Button {
                    Task { await store.refreshConnectionStatuses(forceVerify: true) }
                } label: {
                    Label(L10n.string("action.recheck"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: DesignTokens.Typography.captionSize))
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: DesignTokens.Spacing.sm) {
                ForEach(ProviderID.allCases) { provider in
                    providerSelectorPill(provider)
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
    }

    private func providerSelectorPill(_ provider: ProviderID) -> some View {
        let isSelected = selectedProvider == provider
        let prefs = store.settings.preferences(for: provider)
        let status = store.connectionStatuses[provider] ?? .unknown

        return Button {
            selectedProvider = provider
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                ProviderIconView(provider: provider, size: DesignTokens.Layout.iconMediumSize)
                Text(provider.displayName)
                    .font(.system(size: DesignTokens.Typography.bodySize, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Circle()
                    .fill(statusDotColor(status: status, isEnabled: prefs.isEnabled))
                    .frame(
                        width: DesignTokens.Layout.settingsStatusDotSize,
                        height: DesignTokens.Layout.settingsStatusDotSize
                    )
            }
            .foregroundStyle(DesignTokens.Colors.textPrimary)
            .opacity(prefs.isEnabled ? 1.0 : DesignTokens.Opacity.disabledControl)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                    .fill(isSelected ? DesignTokens.Colors.resetBadgeBackground(provider) : DesignTokens.Colors.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                    .stroke(
                        isSelected ? DesignTokens.Colors.resetBadgeBorder(provider) : DesignTokens.Colors.borderSubtle,
                        lineWidth: DesignTokens.Stroke.hairline
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
        }
        .buttonStyle(.plain)
    }

    private func providerDetailForm(for provider: ProviderID) -> some View {
        let prefs = store.settings.preferences(for: provider)
        let status = store.connectionStatuses[provider] ?? .unknown
        let modelWindows = (store.snapshots[provider]?.windows ?? [])
            .filter { $0.category == .modelSpecific }

        return Form {
            Section {
                Toggle(isOn: Binding(
                    get: { prefs.isEnabled },
                    set: { store.setProviderEnabled($0, for: provider) }
                )) {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        ProviderIconView(provider: provider, size: DesignTokens.Layout.iconMediumSize)
                        Text(L10n.format("settings.provider.enabled", provider.displayName))
                    }
                }
                .toggleStyle(.switch)

                LabeledContent(L10n.string("settings.provider.status")) {
                    if prefs.isEnabled {
                        connectionBadge(status)
                    } else {
                        Text(L10n.string("settings.provider.disabled"))
                            .font(.system(size: DesignTokens.Typography.captionSize))
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                    }
                }
            } header: {
                Text(L10n.string("settings.section.provider_connection"))
            } footer: {
                cliHintText(for: provider)
                    .font(.system(size: DesignTokens.Typography.microSize))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }

            if prefs.isEnabled {
                Section {
                    Toggle(L10n.string("settings.limit.five_hour"), isOn: Binding(
                        get: { prefs.showFiveHour },
                        set: { value in store.updatePreferences({ $0.showFiveHour = value }, for: provider) }
                    ))
                    .toggleStyle(.switch)

                    Toggle(L10n.string("settings.limit.seven_day"), isOn: Binding(
                        get: { prefs.showSevenDay },
                        set: { value in store.updatePreferences({ $0.showSevenDay = value }, for: provider) }
                    ))
                    .toggleStyle(.switch)

                    if provider != .claude {
                        Toggle(L10n.string("settings.limit.model_specific"), isOn: Binding(
                            get: { prefs.showModelSpecific },
                            set: { value in store.updatePreferences({ $0.showModelSpecific = value }, for: provider) }
                        ))
                        .toggleStyle(.switch)
                    }
                } header: {
                    Text(L10n.string("settings.section.provider_limits"))
                }

                if prefs.showModelSpecific && !modelWindows.isEmpty {
                    Section {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading),
                            ],
                            alignment: .leading,
                            spacing: DesignTokens.Spacing.xs
                        ) {
                            ForEach(modelWindows) { window in
                                let cadenceEnabled = isParentCadenceEnabled(for: window, prefs: prefs)
                                Toggle(L10n.localizedWindowLabel(window), isOn: Binding(
                                    get: { !prefs.disabledWindowIDs.contains(window.id) },
                                    set: { enabled in
                                        store.updatePreferences({
                                            if enabled {
                                                $0.disabledWindowIDs.remove(window.id)
                                            } else {
                                                $0.disabledWindowIDs.insert(window.id)
                                            }
                                        }, for: provider)
                                    }
                                ))
                                .toggleStyle(.checkbox)
                                .font(.system(size: DesignTokens.Typography.captionSize))
                                .disabled(!cadenceEnabled)
                                .opacity(cadenceEnabled ? 1.0 : DesignTokens.Opacity.disabledControl)
                            }
                        }
                    } header: {
                        Text(L10n.string("settings.limit.models_discovered"))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .font(.system(size: DesignTokens.Typography.bodySize))
    }

    private func isParentCadenceEnabled(for window: QuotaWindow, prefs: ProviderLimitPreferences) -> Bool {
        guard window.provider == .antigravity else { return true }
        switch window.cadence {
        case .fiveHour: return prefs.showFiveHour
        case .sevenDay: return prefs.showSevenDay
        case .other: return true
        }
    }

    private func statusDotColor(status: ProviderConnectionStatus, isEnabled: Bool) -> Color {
        guard isEnabled else {
            return DesignTokens.Colors.statusNeutral
        }
        return status.isHealthy
            ? DesignTokens.Colors.statusHealthy
            : DesignTokens.Colors.statusWarning
    }

    private func connectionBadge(_ status: ProviderConnectionStatus) -> some View {
        let color: Color = status.isHealthy
            ? DesignTokens.Colors.statusHealthy
            : DesignTokens.Colors.statusWarning
        let icon = status.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        return HStack(spacing: DesignTokens.Spacing.xxs) {
            Image(systemName: icon)
                .font(.system(size: DesignTokens.Typography.captionSize))
            Text(L10n.statusText(status))
                .font(.system(size: DesignTokens.Typography.captionSize, weight: .medium))
        }
        .foregroundStyle(color)
    }

    private func cliHintText(for provider: ProviderID) -> Text {
        switch provider {
        case .claude: return L10n.markdownText("settings.cli_hint.claude")
        case .codex: return L10n.markdownText("settings.cli_hint.codex")
        case .antigravity: return L10n.markdownText("settings.cli_hint.antigravity")
        }
    }
}
