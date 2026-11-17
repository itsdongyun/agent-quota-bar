import SwiftUI
import AgentQuotaCore

/// Settings window for CLI integration status, per-provider limit filtering, refresh cadence, and launch at login.
struct SettingsView: View {
    @Bindable var store: QuotaStore
    @Bindable var launchAtLogin: LaunchAtLoginManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                generalSection
                providersSection
            }
            .padding(DesignTokens.Spacing.lg)
        }
        .frame(width: DesignTokens.Layout.settingsWidth)
        .frame(minHeight: DesignTokens.Layout.settingsMinHeight)
        .task {
            launchAtLogin.refresh()
            await store.refreshConnectionStatuses()
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(L10n.string("settings.section.general"))
                .font(.system(size: DesignTokens.Typography.sectionHeaderSize, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.textSecondary)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack {
                    Label(L10n.string("settings.refresh_interval"), systemImage: "clock")
                        .font(.system(size: DesignTokens.Typography.bodySize))
                    Spacer()
                    Picker("", selection: $store.settings.refreshInterval) {
                        ForEach(RefreshIntervalOption.allCases) { option in
                            Text(L10n.format("settings.interval_minutes", option.minutes))
                                .tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                Divider()

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Toggle(isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )) {
                        Label(L10n.string("settings.launch_at_login"), systemImage: "arrow.up.forward.app")
                            .font(.system(size: DesignTokens.Typography.bodySize))
                    }
                    .disabled(!launchAtLogin.isSupportedInCurrentEnvironment)

                    if !launchAtLogin.isSupportedInCurrentEnvironment {
                        Text(L10n.string("settings.launch_at_login_hint"))
                            .font(.system(size: DesignTokens.Typography.microSize))
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                    }
                }
            }
            .padding(DesignTokens.Spacing.md)
            .background(DesignTokens.Colors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.lg)
                    .stroke(DesignTokens.Colors.borderSubtle, lineWidth: DesignTokens.Stroke.hairline)
            )
            .shadow(
                color: DesignTokens.Colors.shadowColor,
                radius: DesignTokens.Shadow.cardRadius,
                y: DesignTokens.Shadow.cardYOffset
            )
        }
    }

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
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

            ForEach(ProviderID.allCases) { provider in
                providerSettingsCard(provider)
            }
        }
    }

    private func providerSettingsCard(_ provider: ProviderID) -> some View {
        let prefs = store.settings.preferences(for: provider)
        let status = store.connectionStatuses[provider] ?? .unknown
        let modelWindows = (store.snapshots[provider]?.windows ?? [])
            .filter { $0.category == .modelSpecific }

        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Circle()
                    .fill(DesignTokens.Colors.provider(provider))
                    .frame(width: DesignTokens.Layout.providerDotSize, height: DesignTokens.Layout.providerDotSize)
                Toggle(L10n.format("settings.provider.enabled", provider.displayName), isOn: Binding(
                    get: { prefs.isEnabled },
                    set: { store.setProviderEnabled($0, for: provider) }
                ))
                .font(.system(size: DesignTokens.Typography.bodySize, weight: .semibold))
                Spacer()
                connectionBadge(status)
            }

            cliHintText(for: provider)
                .font(.system(size: DesignTokens.Typography.microSize))
                .foregroundStyle(DesignTokens.Colors.textSecondary)

            if prefs.isEnabled {
                Divider()

                HStack(spacing: DesignTokens.Spacing.lg) {
                    Toggle(L10n.string("settings.limit.five_hour"), isOn: Binding(
                        get: { prefs.showFiveHour },
                        set: { value in store.updatePreferences({ $0.showFiveHour = value }, for: provider) }
                    ))
                    Toggle(L10n.string("settings.limit.seven_day"), isOn: Binding(
                        get: { prefs.showSevenDay },
                        set: { value in store.updatePreferences({ $0.showSevenDay = value }, for: provider) }
                    ))
                    Toggle(L10n.string("settings.limit.model_specific"), isOn: Binding(
                        get: { prefs.showModelSpecific },
                        set: { value in store.updatePreferences({ $0.showModelSpecific = value }, for: provider) }
                    ))
                }
                .font(.system(size: DesignTokens.Typography.captionSize))

                if prefs.showModelSpecific && !modelWindows.isEmpty {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                        Text(L10n.string("settings.limit.models_discovered"))
                            .font(.system(size: DesignTokens.Typography.microSize, weight: .medium))
                            .foregroundStyle(DesignTokens.Colors.textSecondary)

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
                            .font(.system(size: DesignTokens.Typography.captionSize))
                            .disabled(!cadenceEnabled)
                            .opacity(cadenceEnabled ? 1.0 : DesignTokens.Opacity.disabledControl)
                        }
                    }
                    .padding(.top, DesignTokens.Spacing.xxs)
                }
            }
        }
        .padding(DesignTokens.Spacing.md)
        .background(DesignTokens.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg)
                .stroke(DesignTokens.Colors.borderSubtle, lineWidth: DesignTokens.Stroke.hairline)
        )
        .shadow(
            color: DesignTokens.Colors.shadowColor,
            radius: DesignTokens.Shadow.cardRadius,
            y: DesignTokens.Shadow.cardYOffset
        )
    }

    private func isParentCadenceEnabled(for window: QuotaWindow, prefs: ProviderLimitPreferences) -> Bool {
        guard window.provider == .antigravity else { return true }
        switch window.cadence {
        case .fiveHour: return prefs.showFiveHour
        case .sevenDay: return prefs.showSevenDay
        case .other: return true
        }
    }

    private func connectionBadge(_ status: ProviderConnectionStatus) -> some View {
        let color: Color = status.isHealthy
            ? DesignTokens.Colors.statusHealthy
            : DesignTokens.Colors.statusWarning
        let icon = status.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        return HStack(spacing: DesignTokens.Spacing.xxs) {
            Image(systemName: icon)
                .font(.system(size: DesignTokens.Typography.microSize))
            Text(L10n.statusText(status))
                .font(.system(size: DesignTokens.Typography.microSize, weight: .medium))
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
