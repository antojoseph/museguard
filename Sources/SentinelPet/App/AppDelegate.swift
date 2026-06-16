import AppKit

/// Owns the lifetime of the floating pet overlay. Kept as a strong reference so
/// the panel and its view model survive for the whole app session.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runtime = SentinelPetRuntime.shared
    private var overlay: PetOverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent app: never bounce into the foreground or show in the Dock.
        NSApp.setActivationPolicy(.accessory)

        runtime.refreshAccessibilityStatus()
        runtime.refreshFireworksAPIKeyStatus()

        let overlay = PetOverlayController(viewModel: runtime.petViewModel)
        overlay.show()
        self.overlay = overlay
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        runtime.refreshAccessibilityStatus()
        runtime.refreshFireworksAPIKeyStatus()
    }
}
