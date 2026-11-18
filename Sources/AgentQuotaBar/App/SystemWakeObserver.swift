import AppKit

/// Calls `onWake` a few seconds after the Mac wakes, once the network has had time to come back.
@MainActor
final class SystemWakeObserver {
    private static let networkSettleDelay: Duration = .seconds(3)
    // Written once in init and read only in deinit.
    nonisolated(unsafe) private var token: NSObjectProtocol?

    init(onWake: @escaping @MainActor () -> Void) {
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: Self.networkSettleDelay)
                onWake()
            }
        }
    }

    deinit {
        if let token {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }
}
