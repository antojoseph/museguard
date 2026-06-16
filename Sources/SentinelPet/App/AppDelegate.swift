import AppKit

/// Owns the lifetime of the floating pet overlay. Kept as a strong reference so
/// the panel and its view model survive for the whole app session.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlay: PetOverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent app: never bounce into the foreground or show in the Dock.
        NSApp.setActivationPolicy(.accessory)

        let overlay = PetOverlayController()
        overlay.show()
        self.overlay = overlay
    }
}
