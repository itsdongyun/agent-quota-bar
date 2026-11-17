import Foundation
import ServiceManagement
import AgentQuotaCore

/// Manages Login Item registration via `SMAppService.mainApp`.
@MainActor
@Observable
final class LaunchAtLoginManager {
    private(set) var isEnabled: Bool = false
    private(set) var isSupportedInCurrentEnvironment: Bool = false

    init() {
        refresh()
    }

    func refresh() {
        let isBundle = Bundle.main.bundleURL.pathExtension == "app"
        isSupportedInCurrentEnvironment = isBundle
        guard isBundle else {
            isEnabled = false
            return
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        guard isSupportedInCurrentEnvironment else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            refresh()
        } catch {
            AppLogger.app.error("LaunchAtLogin update failed: \(error.localizedDescription)")
            refresh()
        }
    }
}
