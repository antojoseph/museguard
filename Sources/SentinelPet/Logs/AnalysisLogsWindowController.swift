import AppKit
import SwiftUI

@MainActor
final class AnalysisLogsWindowController {
    private weak var window: NSWindow?

    func show(runtime: SentinelPetRuntime) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: AnalysisLogsView(runtime: runtime))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Muse Guard Logs"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 560))
        window.center()
        window.isReleasedWhenClosed = false

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
