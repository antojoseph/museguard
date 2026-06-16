import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private weak var window: NSWindow?

    func show(runtime: SentinelPetRuntime) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: SettingsView(runtime: runtime))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Sentinel Pet Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 560, height: 600))
        window.center()
        window.isReleasedWhenClosed = false

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
