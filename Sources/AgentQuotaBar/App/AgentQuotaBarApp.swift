import AppKit
import SwiftUI
import AgentQuotaCore

@main
struct AgentQuotaBarApp: App {
    @AppStorage("AgentQuotaBar.PopoverChartLayout") private var chartLayout: PopoverChartLayout = .byProvider
    @AppStorage("AgentQuotaBar.PopoverResetLayout") private var resetLayout: PopoverResetLayout = .providerColumns
    @State private var store: QuotaStore
    @State private var launchAtLogin: LaunchAtLoginManager
    /// Set only when launched with `--mock-data`.
    @State private var mockController: MockDataController?

    init() {
        let (quotaStore, mockController) = Self.makeStore()
        _store = State(initialValue: quotaStore)
        _launchAtLogin = State(initialValue: LaunchAtLoginManager())
        _mockController = State(initialValue: mockController)
        quotaStore.start()
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(
                store: store,
                chartLayout: chartLayout,
                resetLayout: resetLayout,
                isMockMode: mockController != nil
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

        Window(L10n.string("mock.title"), id: "mock-data") {
            if let mockController {
                MockDataControlView(controller: mockController)
                    .background(DesktopWindowPresence())
            }
        }
        .windowResizability(.contentSize)
    }

    /// `--mock-data` swaps every provider for live-editable mock data (see `MockDataControlView`).
    private static func makeStore() -> (QuotaStore, MockDataController?) {
        guard CommandLine.arguments.contains("--mock-data") else {
            return (QuotaStore(), nil)
        }
        let source = MockScenarioSource()
        let store = QuotaStore(
            providers: MockQuotaProvider.all(source: source),
            announcementService: CodexResetAnnouncementService(
                transport: MockAnnouncementTransport(source: source),
                minimumFetchInterval: 0
            )
        )
        return (store, MockDataController(source: source, store: store))
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
