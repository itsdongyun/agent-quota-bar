import SwiftUI
import AgentQuotaCore

/// Mock-mode control panel: presets plus per-provider status, plan, and window values.
/// Every change applies to the popover and menu bar immediately.
struct MockDataControlView: View {
    @Bindable var controller: MockDataController

    private let presetColumns = Array(
        repeating: GridItem(.flexible(), spacing: DesignTokens.Spacing.xs),
        count: DesignTokens.Layout.mockPresetColumns
    )

    var body: some View {
        Form {
            Section(L10n.string("mock.section.presets")) {
                LazyVGrid(columns: presetColumns, spacing: DesignTokens.Spacing.xs) {
                    ForEach(MockScenarioPreset.allCases) { preset in
                        Button {
                            controller.apply(preset)
                        } label: {
                            Text(L10n.mockPresetTitle(preset))
                                .font(.system(size: DesignTokens.Typography.captionSize, weight: .medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            ForEach(ProviderID.allCases) { provider in
                providerSection(provider)
            }

            Section(L10n.string("mock.section.other")) {
                Toggle(L10n.string("mock.codex_banner"), isOn: $controller.scenario.codexResetBanner)
            }
        }
        .formStyle(.grouped)
        .frame(width: DesignTokens.Layout.mockControlWidth)
        .frame(minHeight: DesignTokens.Layout.mockControlMinHeight)
    }

    private func providerSection(_ provider: ProviderID) -> some View {
        let state = $controller.scenario[provider]
        return Section {
            Picker(L10n.string("mock.status"), selection: state.status) {
                ForEach(MockProviderStatus.allCases) { status in
                    Text(L10n.mockStatusTitle(status)).tag(status)
                }
            }
            TextField(L10n.string("mock.plan"), text: state.plan)
            Picker(L10n.string("mock.short_cadence"), selection: state.shortCadence) {
                ForEach(MockShortCadence.allCases) { cadence in
                    Text(L10n.mockCadenceTitle(cadence)).tag(cadence)
                }
            }
            .pickerStyle(.segmented)
            windowControls(L10n.slotTitle(.short), window: state.short)
            windowControls(L10n.slotTitle(.weekly), window: state.weekly)
        } header: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Circle()
                    .fill(DesignTokens.Colors.provider(provider))
                    .frame(width: DesignTokens.Layout.providerDotSize, height: DesignTokens.Layout.providerDotSize)
                Text(provider.displayName)
            }
        }
    }

    @ViewBuilder
    private func windowControls(_ title: String, window: Binding<MockWindowState>) -> some View {
        Toggle(title, isOn: window.isEnabled)
        if window.wrappedValue.isEnabled {
            valueSlider(L10n.string("mock.used"), value: window.used, range: 0...100)
            valueSlider(
                L10n.string("mock.elapsed"),
                value: Binding(
                    get: { window.wrappedValue.elapsed * 100 },
                    set: { window.wrappedValue.elapsed = $0 / 100 }
                ),
                range: 0...100
            )
        }
    }

    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(title)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .padding(.leading, DesignTokens.Spacing.md)
            Slider(value: value, in: range, step: 1)
            Text("\(Int(value.wrappedValue.rounded()))%")
                .monospacedDigit()
                .frame(width: DesignTokens.Layout.mockValueLabelWidth, alignment: .trailing)
        }
    }
}
