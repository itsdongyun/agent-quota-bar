import AppKit
import SwiftUI

/// Tracks the settings window for Dock and app-switcher presence.
struct DesktopWindowPresence: NSViewRepresentable {
    static func prepareToOpen() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func makeNSView(context: Context) -> WindowObserver {
        WindowObserver()
    }

    func updateNSView(_ nsView: WindowObserver, context: Context) {}

    final class WindowObserver: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                DesktopWindows.shared.track(window)
            }
        }
    }
}

@MainActor
private final class DesktopWindows: NSObject {
    static let shared = DesktopWindows()

    private let trackedWindows = NSHashTable<NSWindow>.weakObjects()
    private let openWindows = NSHashTable<NSWindow>.weakObjects()

    func track(_ window: NSWindow) {
        if !trackedWindows.contains(window) {
            trackedWindows.add(window)
            window.hidesOnDeactivate = false

            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(windowDidBecomeKey(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: window)
        }
        markOpen(window)
    }

    private func markOpen(_ window: NSWindow) {
        openWindows.add(window)
        DesktopWindowPresence.prepareToOpen()
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            markOpen(window)
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        openWindows.remove(window)

        DispatchQueue.main.async {
            if self.openWindows.allObjects.isEmpty {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
