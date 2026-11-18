import AppKit
import SwiftUI
import AgentQuotaCore

@main
struct AgentQuotaBarApp: App {
    @AppStorage("AgentQuotaBar.PopoverChartLayout") private var chartLayout: PopoverChartLayout = .byProvider
    @AppStorage("AgentQuotaBar.PopoverResetLayout") private var resetLayout: PopoverResetLayout = .providerColumns
    @AppStorage("AgentQuotaBar.MenuBarStyle") private var menuBarStyle: MenuBarStyle = .ringsWithPercent
    @State private var store: QuotaStore
    @State private var launchAtLogin: LaunchAtLoginManager
    @State private var claudeLogin: ClaudeLoginCoordinator
    @State private var wakeObserver: SystemWakeObserver

    init() {
        // Claude used to keep a 429 cooldown here; backoff now lives in QuotaStore.
        UserDefaults.standard.removeObject(forKey: "AgentQuotaBar.RateLimitCooldown.claude.v1")
        let quotaStore = QuotaStore()
        _store = State(initialValue: quotaStore)
        _launchAtLogin = State(initialValue: LaunchAtLoginManager())
        _claudeLogin = State(initialValue: ClaudeLoginCoordinator(store: quotaStore))
        _wakeObserver = State(initialValue: SystemWakeObserver { quotaStore.handleSystemWake() })
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
            MenuBarIconView(style: menuBarStyle, rings: rings.rings, accessibilityText: rings.accessibilityText)
        }
        .menuBarExtraStyle(.window)

        Window(L10n.string("settings.title"), id: "settings") {
            SettingsView(
                store: store,
                launchAtLogin: launchAtLogin,
                claudeLogin: claudeLogin,
                menuBarStyle: $menuBarStyle,
                chartLayout: $chartLayout,
                resetLayout: $resetLayout
            )
            .background(DesktopWindowPresence())
        }
        .windowResizability(.contentSize)
    }

    /// Each ring shows the provider's short-term (5-hour, or daily where that is the short window) usage
    /// in the provider's fixed color. A provider without a short window shows an empty ring.
    private func menuBarRings() -> (rings: [MenuBarRing], accessibilityText: String) {
        var parts: [String] = []
        let now = Date()
        let rings = store.usageSummaries(now: now).map { summary in
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
