import AppKit
import SwiftUI
import AgentQuotaCore

@main
struct AgentQuotaBarApp: App {
    @AppStorage("AgentQuotaBar.PopoverChartLayout") private var chartLayout: PopoverChartLayout = .byProvider
    @AppStorage("AgentQuotaBar.PopoverResetLayout") private var resetLayout: PopoverResetLayout = .providerColumns
    @State private var store: QuotaStore
    @State private var launchAtLogin: LaunchAtLoginManager

    init() {
        let quotaStore = QuotaStore()
        _store = State(initialValue: quotaStore)
        _launchAtLogin = State(initialValue: LaunchAtLoginManager())
        quotaStore.start()
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(
                store: store,
                chartLayout: chartLayout,
                resetLayout: resetLayout
            )
        } label: {
            let rings = menuBarRings()
            MenuBarIconView(rings: rings.rings, accessibilityText: rings.accessibilityText)
        }
        .menuBarExtraStyle(.window)

        Window(L10n.string("settings.title"), id: "settings") {
            SettingsView(
                store: store,
                launchAtLogin: launchAtLogin,
                chartLayout: $chartLayout,
                resetLayout: $resetLayout
            )
            .background(DesktopWindowPresence())
        }
        .windowResizability(.contentSize)
    }

    /// Each ring shows the provider's short-window usage in the provider's fixed color.
    private func menuBarRings() -> (rings: [MenuBarRing], accessibilityText: String) {
        var parts: [String] = []
        let rings = store.usageSummaries().map { summary in
            let window = summary.short
            if let window {
                parts.append("\(summary.provider.displayName) \(Int(window.usedPercent.rounded()))%")
            }
            return MenuBarRing(
                provider: summary.provider,
                fraction: window.map { $0.usedPercent / 100 },
                color: DesignTokens.Colors.provider(summary.provider)
            )
        }
        let title = L10n.string("app.title")
        return (rings, parts.isEmpty ? title : "\(title): \(parts.joined(separator: ", "))")
    }
}
